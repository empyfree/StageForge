# frozen_string_literal: true

module StageForge
  # Seating: any number of "banks" (an area + front + chair + layout settings, each stored on its
  # own tagged group) that all react to one shared set of aisle markers (tagged in the model).
  module SeatingUI
    STATE_KEY = 'seating_state'
    TAG = 'StageForge'
    FACING = {
      '+x' => [1.0, 0.0], '-x' => [-1.0, 0.0], '+y' => [0.0, 1.0], '-y' => [0.0, -1.0]
    }.freeze

    # One block of seating. group is the tagged group holding the placed chairs (nil until placed).
    Bank = Struct.new(:id, :name, :group, :params, :front, :focal, :chair, :boundary, :boundary_pid,
                      :layout, :chairs, :mode, :boundary_edges, :tables)

    @dlg = nil
    @banks = []
    @cur = nil
    @aisles = []
    @aisle_sigs = nil
    @bank_sigs = {}
    @obs_sigs = {}
    @last = nil
    @live = false
    @busy = false
    @timer = nil
    @watched = []
    @observer = nil
    @model_observer = nil
    @sel_observer = nil
    @observed_model = nil

    # Click-to-pick a point in the model (used for the curved-row focal point).
    class PointPicker
      def initialize(&callback)
        @callback = callback
        @ip = Sketchup::InputPoint.new
      end

      def activate
        Sketchup.status_text = 'Click the focal point (centre of the curved rows). Esc to cancel.'
      end

      def deactivate(view)
        view.invalidate
      end

      def onMouseMove(_flags, x, y, view)
        @ip.pick(view, x, y)
        view.tooltip = @ip.tooltip
        view.invalidate
      end

      def onLButtonDown(_flags, x, y, view)
        @ip.pick(view, x, y)
        @callback.call(@ip.position)
        Sketchup.active_model.select_tool(nil)
        view.invalidate
      end

      def draw(view)
        @ip.draw(view) if @ip.valid?
      end
    end

    # Tells us when a watched aisle marker or seating area is moved or edited.
    class LiveObserver < Sketchup::EntityObserver
      def onChangeEntity(entity)
        SeatingUI.entity_changed(entity)
      end

      def onEraseEntity(entity)
        SeatingUI.entity_changed(entity)
      end
    end

    class ModelWatcher < Sketchup::ModelObserver
      def onTransactionUndo(_model)
        SeatingUI.after_undo_redo
      end

      def onTransactionRedo(_model)
        SeatingUI.after_undo_redo
      end

      # Every finished edit: catches reshaping an aisle marker (even inside a group).
      def onTransactionCommit(_model)
        SeatingUI.entity_changed(nil)
      end
    end

    # Clicking a seating group in the model makes it the bank being edited.
    class SelWatcher < Sketchup::SelectionObserver
      def onSelectionBulkChange(sel)
        SeatingUI.selection_changed(sel)
      end

      def onSelectionAdded(sel, _e)
        SeatingUI.selection_changed(sel)
      end
    end

    # ---------------- helpers ----------------
    def self.system_of(s)
      s.to_s == 'imperial' ? 'imperial' : 'metric'
    end

    def self.push(fn, obj = nil)
      return unless @dlg
      arg = obj.nil? ? '' : JSON.generate(obj)
      @dlg.execute_script("SE.#{fn}(#{arg})")
    end

    def self.pid_of(e)
      e.valid? && e.respond_to?(:persistent_id) ? e.persistent_id : nil
    rescue StandardError
      nil
    end

    def self.find_pid(model, pid)
      return nil unless pid && model.respond_to?(:find_entity_by_persistent_id)
      e = model.find_entity_by_persistent_id(pid)
      e && e.valid? ? e : nil
    rescue StandardError
      nil
    end

    def self.symbolize(h)
      return h unless h.is_a?(Hash)
      h.each_with_object({}) { |(k, v), o| o[k.to_sym] = v }
    end

    def self.new_bank(from = nil)
      n = @banks.size + 1
      n += 1 while @banks.any? { |b| b.name == "Bank #{n}" } || (@cur && @cur.name == "Bank #{n}")
      bk = Bank.new("sf#{Time.now.to_i}#{rand(1_000_000)}", "Bank #{n}")
      if from
        bk.params = from.params && from.params.dup
        bk.front = from.front && Marshal.load(Marshal.dump(from.front))
        bk.focal = from.focal && from.focal.dup
        bk.chair = from.chair && from.chair.dup
      end
      bk
    end

    def self.cur
      @cur ||= new_bank
    end

    # ---------------- finding things in the model ----------------
    def self.each_tagged(ents, depth, &blk)
      ents.each do |e|
        case e
        when Sketchup::Face, Sketchup::ComponentInstance
          blk.call(e)
        when Sketchup::Group
          blk.call(e)
          next if depth <= 0 || e.get_attribute(TAG, 'set_id')
          each_tagged(e.entities, depth - 1, &blk)
        end
      end
    end

    # Rebuilds the list of aisle markers and seating banks from what is tagged in the model.
    def self.scan(model)
      aisles = []
      groups = []
      each_tagged(model.entities, 3) do |e|
        aisles << e if e.get_attribute(TAG, 'aisle')
        groups << e if e.is_a?(Sketchup::Group) && e.get_attribute(TAG, 'set_id')
      end
      @aisles = aisles
      groups.each do |g|
        id = g.get_attribute(TAG, 'set_id')
        known = @banks.find { |b| b.id == id }
        if known
          known.group = g
        else
          bk = load_bank(g)
          @banks << bk if bk
        end
      end
      # Banks whose group has been deleted (or undone away) are gone.
      @banks.select! { |b| b.group && b.group.valid? && groups.include?(b.group) }
      @cur = @banks.find { |b| @cur && b.id == @cur.id } || @cur
      @aisle_sigs = aisle_poly_map
    end

    def self.load_bank(g)
      raw = g.get_attribute(TAG, 'seating')
      return nil if raw.to_s.empty?
      d = JSON.parse(raw)
      model = Sketchup.active_model
      bk = Bank.new(d['id'] || g.get_attribute(TAG, 'set_id'), d['name'] || 'Bank')
      bk.group = g
      bk.params = d['params']
      bk.front = d['front'] ? symbolize(d['front']) : nil
      bk.focal = d['focal']
      if d['chair'] && d['chair']['defn']
        defn = model.definitions[d['chair']['defn']]
        bk.chair = symbolize(d['chair']).merge(defn: defn) if defn && defn.valid?
      end
      bk.boundary_pid = d['boundary']
      bk.boundary_edges = d['boundary_edges']
      bk.mode = bk.params && (bk.params['kind'] == 'tables' ? "#{bk.params['t_arr']} #{bk.params['t_layout']}" : bk.params['mode'])
      bk
    rescue StandardError => e
      puts "#{StageForge.tag} could not read seating settings: #{e.message}"
      nil
    end

    # The bank's area, re-read from its source entity (it may have been moved or edited).
    def self.bank_boundary(bank, model = Sketchup.active_model)
      src = bank.boundary && bank.boundary[:src]
      src = nil unless src && src.valid?
      src ||= find_pid(model, bank.boundary_pid)
      return nil unless src
      bank.boundary = StageForge.boundary_from_source(src, bank.boundary_edges, model)
      bank.boundary_pid = pid_of(src) || bank.boundary_pid
      bank.boundary_edges = bank.boundary[:edge_pids] || bank.boundary_edges
      bank.boundary
    rescue StandardError
      nil
    end

    def self.bank_for_group(g)
      id = g.get_attribute(TAG, 'set_id')
      @banks.find { |b| b.id == id }
    end

    # ---------------- aisles (shared by every bank) ----------------
    def self.poly_round(o)
      o.map { |p| [p[0].round(2), p[1].round(2)] }
    end

    def self.aisle_poly_map
      h = {}
      @aisles.each do |e|
        next unless e.valid?
        polys = StageForge.horizontal_faces(e).map { |f, t| StageForge.face_polygon(f, t)[:outer] }
        h[pid_of(e) || e.object_id] = polys.select { |o| o.size >= 3 }.map { |o| poly_round(o) }
      end
      h
    end

    def self.aisle_polygons
      @aisles.select(&:valid?).flat_map do |e|
        StageForge.horizontal_faces(e).map { |f, t| StageForge.face_polygon(f, t)[:outer] }
      end.select { |o| o.size >= 3 }
    end

    def self.aisle_regions
      aisle_polygons.map { |o| Packer::Region.new(o, []) }
    end

    def self.aisle_info(system)
      polys = aisle_polygons
      return nil if polys.empty?
      { count: @aisles.count(&:valid?), area: Units.area(polys.map { |o| Packer.polygon_area(o) }.sum, system) }
    end

    def self.mark_aisles(model)
      items = model.selection.select do |e|
        e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      end
      items = items.reject { |e| e.is_a?(Sketchup::Group) && e.get_attribute(TAG, 'set_id') }
      items = items.select { |e| StageForge.horizontal_faces(e).any? }
      raise 'Select one or more flat faces, or groups containing a flat face, to use as aisles.' if items.empty?
      areas = @banks.map { |b| b.boundary && b.boundary[:src] }.compact + [cur.boundary && cur.boundary[:src]].compact
      items = items.reject { |e| areas.include?(e) }
      raise 'That is a seating area itself. Select the aisle markers instead.' if items.empty?
      model.start_operation('StageForge: mark aisles', true)
      items.each do |e|
        e.set_attribute(TAG, 'aisle', true)
        @aisles << e unless @aisles.include?(e)
      end
      model.commit_operation
    rescue StandardError
      model.abort_operation
      raise
    end

    def self.unmark_aisles(model, all)
      targets = all ? @aisles.select(&:valid?) : model.selection.select { |e| @aisles.include?(e) }
      raise 'Select the aisle markers to remove from the aisles.' if targets.empty? && !all
      model.start_operation('StageForge: unmark aisles', true)
      targets.each { |e| e.delete_attribute(TAG, 'aisle') }
      @aisles -= targets
      model.commit_operation
    rescue StandardError
      model.abort_operation
      raise
    end

    # Objects the person has told us not to avoid (ground, terrain, a venue shell...).
    def self.set_ignored(model, on)
      items = model.selection.select do |e|
        e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      end
      raise 'Select the group(s) or component(s) to ' + (on ? 'ignore.' : 'stop ignoring.') if items.empty?
      model.start_operation('StageForge: ignore objects', true)
      items.each do |e|
        if on
          e.set_attribute(TAG, 'ignore', true)
        else
          e.delete_attribute(TAG, 'ignore')
        end
      end
      model.commit_operation
      items.size
    rescue StandardError
      model.abort_operation
      raise
    end

    # Re-lays every placed bank (e.g. after objects were moved or ignored).
    def self.refresh_all
      @busy = true
      begin
        push('onLive', 'working')
        @banks.dup.each do |bk|
          next unless bk.params && bk.group && bk.group.valid?
          begin
            lay_out(bk, bk.params, live: true, transparent: false)
          rescue StandardError => e
            push('onError', "#{bk.name}: #{e.message}")
          end
        end
        push_banks
        push('onRefreshed', @banks.count(&:params))
      ensure
        @busy = false
        watch_all
      end
    end

    # ---------------- live updating ----------------
    def self.watch_all
      unwatch_all
      return unless @live
      @observer ||= LiveObserver.new
      targets = @aisles.select(&:valid?)
      @banks.each do |bk|
        src = bk.boundary && bk.boundary[:src]
        targets << src if src && src.valid?
        (bk.boundary && bk.boundary[:edges] || []).each { |e| targets << e if e.valid? }
      end
      targets.uniq.each do |e|
        e.add_observer(@observer)
        @watched << e
      end
    end

    def self.unwatch_all
      @watched.each { |e| e.remove_observer(@observer) if e.valid? }
      @watched = []
    end

    def self.attach_observers(model)
      return if @observed_model && @observed_model == model
      detach_observers
      @sel_observer ||= SelWatcher.new
      model.selection.add_observer(@sel_observer)
      @observed_model = model
    end

    def self.detach_observers
      m = @observed_model
      m.selection.remove_observer(@sel_observer) if m && @sel_observer
      @observed_model = nil
    rescue StandardError
      @observed_model = nil
    end

    def self.set_live(on)
      model = Sketchup.active_model
      if on
        raise 'Place seating once first, then switch on automatic updates.' unless @banks.any?(&:params)
        @live = true
        @model_observer ||= ModelWatcher.new
        model.add_observer(@model_observer)
        watch_all
        entity_changed(nil)
      else
        @live = false
        model.remove_observer(@model_observer) if @model_observer
        unwatch_all
        UI.stop_timer(@timer) if @timer
        @timer = nil
      end
    end

    # Debounced: re-lays the affected banks once things have been still for a moment, so
    # dragging an aisle does not trigger a layout on every mouse move.
    def self.entity_changed(_entity)
      return unless @live && !@busy
      UI.stop_timer(@timer) if @timer
      @timer = UI.start_timer(0.7, false) do
        @timer = nil
        process_changes(true)
      end
    end

    def self.after_undo_redo
      return unless @live
      scan(Sketchup.active_model)
      watch_all
      entity_changed(nil)
    end

    def self.poly_bbox(o)
      xs = o.map { |p| p[0] }
      ys = o.map { |p| p[1] }
      [xs.min, ys.min, xs.max, ys.max]
    end

    def self.boxes_overlap?(a, b, tol = 0.5)
      !(a[2] < b[0] - tol || a[0] > b[2] + tol || a[3] < b[1] - tol || a[1] > b[3] + tol)
    end

    # Works out which banks are affected by changed aisles (those they overlap) or by their own
    # area changing, and re-lays just those. Used for live edits and after (un)marking aisles.
    def self.process_changes(transparent)
      return if @busy
      model = Sketchup.active_model
      new_map = aisle_poly_map
      old_map = @aisle_sigs || new_map
      boxes = []
      (new_map.keys | old_map.keys).each do |k|
        next if new_map[k] == old_map[k]
        [new_map[k], old_map[k]].compact.each { |polys| polys.each { |o| boxes << poly_bbox(o) } }
      end
      @aisle_sigs = new_map
      affected = []
      @banks.dup.each do |bk|
        next unless bk.group && bk.group.valid? && bk.params
        b = bank_boundary(bk, model)
        next unless b
        sig = poly_round(b[:outer])
        prev = (@bank_sigs[bk.id] ||= sig)
        affected << bk if prev != sig || boxes.any? { |bx| boxes_overlap?(bx, b[:bb]) }
      end
      movable = @banks.select { |bk| bk.params && bk.group && bk.group.valid? && !affected.include?(bk) }
      affected.concat(banks_with_moved_obstacles(model, movable))
      return if affected.empty?
      @busy = true
      begin
        push('onLive', 'working')
        affected.each do |bk|
          begin
            lay_out(bk, bk.params, live: true, transparent: transparent)
          rescue StandardError => e
            push('onError', "#{bk.name}: #{e.message}")
            puts "#{StageForge.tag} live seating error (#{bk.name}): #{e.message}"
          end
        end
        push_banks
      ensure
        @busy = false
        watch_all
      end
    end

    # ---------------- reading the model ----------------
    def self.read_area(model)
      prev = StageForge.boundary # the stage tool keeps its own boundary
      b = StageForge.read_boundary(model)
      StageForge.boundary = prev
      b
    end

    def self.read_chair(model)
      inst = model.selection.grep(Sketchup::ComponentInstance).first
      raise 'Select the chair first. It must be a component (right-click > Make Component if it is a plain group).' unless inst
      d = inst.definition
      bb = d.bounds
      t = inst.transformation
      cur.chair = {
        defn: d, name: d.name.to_s.empty? ? 'Chair' : d.name,
        sx: t.xscale.abs, sy: t.yscale.abs, sz: t.zscale.abs,
        minx: bb.min.x.to_f, maxx: bb.max.x.to_f, miny: bb.min.y.to_f, maxy: bb.max.y.to_f,
        minz: bb.min.z.to_f, maxz: bb.max.z.to_f
      }
    end

    def self.chair_info(bank, system)
      c = bank.chair
      return nil unless c
      w = (c[:maxx] - c[:minx]) * c[:sx]
      h = (c[:maxy] - c[:miny]) * c[:sy]
      { name: c[:name], size: "#{Units.len(w, system)} (along X) × #{Units.len(h, system)} (along Y)" }
    end

    def self.read_front(model)
      sel = model.selection
      objs = sel.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
      if (o = objs.first)
        bb = o.definition.bounds
        t = o.transformation
        corners = [[bb.min.x, bb.min.y], [bb.max.x, bb.min.y], [bb.max.x, bb.max.y], [bb.min.x, bb.max.y]].map do |x, y|
          p = t * Geom::Point3d.new(x, y, 0)
          [p.x.to_f, p.y.to_f]
        end
        corners.reverse! if Packer.signed_area(corners) < 0
        nm = o.name.to_s.empty? ? o.definition.name.to_s : o.name.to_s
        cur.front = { kind: 'object', name: nm.empty? ? 'object' : nm, corners: corners }
      else
        edges = sel.grep(Sketchup::Edge)
        raise 'Select a line/edge, or an object (group or component such as the stage), to mark the front.' if edges.empty?
        pts = edges.flat_map { |e| [e.start.position, e.end.position] }.map { |p| [p.x.to_f, p.y.to_f] }
        best = nil
        bd = -1.0
        pts.each_with_index do |a, i|
          pts[(i + 1)..-1].each do |b|
            d = Math.hypot(a[0] - b[0], a[1] - b[1])
            if d > bd
              bd = d
              best = [a, b]
            end
          end
        end
        raise 'That line is too short (or vertical) to define a front.' if best.nil? || bd < Packer::EPS
        cur.front = { kind: 'line', p1: best[0], p2: best[1] }
      end
    end

    def self.front_info(bank, system)
      f = bank.front
      return nil unless f
      if f[:kind] == 'object'
        { text: "Object \"#{f[:name]}\" (the side facing the seating becomes the front)" }
      else
        len = Math.hypot(f[:p2][0] - f[:p1][0], f[:p2][1] - f[:p1][1])
        { text: "Line, #{Units.len(len, system)} long" }
      end
    end

    # Turns the stored front into { mid:, f:, centre: } using the seating area's centroid
    # to decide which side the audience is on.
    def self.resolve_front(bank, c)
      f = bank.front
      raise 'Mark the front first (select a line or an object, then click "Use selection as front").' unless f
      if f[:kind] == 'line'
        p1 = f[:p1]
        p2 = f[:p2]
        mid = [(p1[0] + p2[0]) / 2.0, (p1[1] + p2[1]) / 2.0]
        l = Math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        n = [-(p2[1] - p1[1]) / l, (p2[0] - p1[0]) / l]
        n = [-n[0], -n[1]] if n[0] * (mid[0] - c[0]) + n[1] * (mid[1] - c[1]) < 0
        { mid: mid, f: n, centre: mid }
      else
        cs = f[:corners]
        best = nil
        bs = -Float::INFINITY
        4.times do |i|
          a = cs[i]
          b = cs[(i + 1) % 4]
          mid = [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
          e = [b[0] - a[0], b[1] - a[1]]
          el = Math.hypot(e[0], e[1])
          next if el < Packer::EPS
          nout = [e[1] / el, -e[0] / el]
          dx = c[0] - mid[0]
          dy = c[1] - mid[1]
          dl = Math.hypot(dx, dy)
          score = dl < 1e-9 ? 0.0 : (nout[0] * dx + nout[1] * dy) / dl
          if score > bs
            bs = score
            best = { mid: mid, f: [-nout[0], -nout[1]] }
          end
        end
        best[:centre] = [cs.map { |p| p[0] }.sum / 4.0, cs.map { |p| p[1] }.sum / 4.0]
        best
      end
    end

    # ---------------- bank list / dialog state ----------------
    def self.bank_label(bk)
      n = bk.chairs ? "#{bk.tables ? "#{bk.tables} tables, " : ''}#{bk.chairs} chairs" : 'not placed'
      mode = bk.mode ? ", #{bk.mode}" : ''
      "#{bk.name} – #{n}#{mode}"
    end

    def self.push_banks
      list = @banks.map { |b| { id: b.id, label: bank_label(b) } }
      c = cur
      list << { id: c.id, label: bank_label(c) } unless @banks.include?(c)
      push('onBanks', { list: list, cur: c.id })
    end

    # Loads a bank's settings into the dialog (area, front, chair, aisles, layout settings).
    def self.push_bank_state(sys = nil)
      c = cur
      sys ||= system_of(c.params && c.params['units'] || load_state['units'])
      b = bank_boundary(c)
      push('onAdopt', {
             params: c.params, name: c.name,
             boundary: b ? StageForge.boundary_info(b, sys) : nil,
             front: front_info(c, sys), aisles: aisle_info(sys), chair: chair_info(c, sys),
             focal: c.focal ? { text: "X #{Units.len(c.focal[0], sys)}, Y #{Units.len(c.focal[1], sys)}" } : nil
           })
      push_banks
    end

    def self.activate(bank)
      @cur = bank
      watch_all
      push_bank_state
    end

    def self.selection_changed(sel)
      return unless @dlg && @dlg.visible?
      return unless sel.size == 1
      g = sel.first
      return unless g.is_a?(Sketchup::Group) && g.valid? && g.get_attribute(TAG, 'set_id')
      return if @cur && g.get_attribute(TAG, 'set_id') == @cur.id
      UI.start_timer(0.05, false) do
        bk = bank_for_group(g)
        unless bk
          scan(Sketchup.active_model)
          bk = bank_for_group(g)
        end
        activate(bk) if bk
      end
    end

    # ---------------- dialog ----------------
    def self.load_state
      raw = Sketchup.read_default(PREF_KEY, STATE_KEY, '')
      raw.to_s.empty? ? {} : JSON.parse(raw)
    rescue StandardError
      {}
    end

    def self.show_dialog
      if @dlg && @dlg.visible?
        @dlg.bring_to_front
        return
      end
      @dlg = UI::HtmlDialog.new(
        dialog_title: "StageForge v#{VERSION} - Seating", preferences_key: 'StageForge.Seating', scrollable: true,
        resizable: true, width: 980, height: 820, min_width: 760, min_height: 560,
        style: UI::HtmlDialog::STYLE_DIALOG
      )
      @dlg.set_file(File.join(DIR, 'html', 'seating.html'))

      @dlg.add_action_callback('ready') do |_c, _a|
        model = Sketchup.active_model
        scan(model)
        attach_observers(model)
        push('init', { state: load_state, version: VERSION })
        push_bank_state
      end

      @dlg.add_action_callback('save_state') do |_c, json|
        Sketchup.write_default(PREF_KEY, STATE_KEY, json.to_s)
      end

      guarded = lambda do |&blk|
        begin
          blk.call
        rescue StandardError => e
          push('onError', e.message)
          puts "#{StageForge.tag} seating error: #{e.message}"
        end
      end

      @dlg.set_on_closed do
        set_live(false)
        detach_observers
      end

      @dlg.add_action_callback('set_live') do |_c, flag|
        guarded.call do
          begin
            set_live(flag.to_s == 'true')
            push('onLiveState', @live)
          rescue StandardError
            push('onLiveState', false)
            raise
          end
        end
      end

      @dlg.add_action_callback('apply_live') do |_c, json|
        guarded.call do
          next unless @live && !@busy && cur.group && cur.group.valid?
          cur.params = JSON.parse(json)
          relayout_current
        end
      end

      @dlg.add_action_callback('show_as') do |_c, mode|
        guarded.call { show_all(mode.to_s == 'boxes' ? 'boxes' : 'chair') }
      end

      @dlg.add_action_callback('new_bank') do |_c, _a|
        @cur = new_bank(cur)
        push_bank_state
      end

      @dlg.add_action_callback('select_bank') do |_c, id|
        bk = @banks.find { |b| b.id == id.to_s }
        next unless bk
        activate(bk)
        g = bk.group
        if g && g.valid?
          sel = Sketchup.active_model.selection
          sel.clear
          sel.add(g)
        end
      end

      @dlg.add_action_callback('delete_bank') do |_c, _a|
        guarded.call do
          bk = cur
          model = Sketchup.active_model
          if bk.group && bk.group.valid?
            model.start_operation('StageForge: delete seating bank', true)
            bk.group.erase!
            model.commit_operation
          end
          @banks.delete(bk)
          @cur = @banks.first || new_bank
          watch_all
          push_bank_state
        end
      end

      @dlg.add_action_callback('use_boundary') do |_c, system|
        guarded.call do
          b = read_area(Sketchup.active_model)
          cur.boundary = b
          cur.boundary_pid = pid_of(b[:src])
          cur.boundary_edges = b[:edge_pids]
          push('onBoundary', StageForge.boundary_info(b, system_of(system)))
          watch_all
        end
      end

      @dlg.add_action_callback('use_chair') do |_c, system|
        guarded.call do
          read_chair(Sketchup.active_model)
          push('onChair', chair_info(cur, system_of(system)))
        end
      end

      @dlg.add_action_callback('use_front') do |_c, system|
        guarded.call do
          read_front(Sketchup.active_model)
          push('onFront', front_info(cur, system_of(system)))
        end
      end

      @dlg.add_action_callback('add_aisles') do |_c, system|
        guarded.call do
          mark_aisles(Sketchup.active_model)
          push('onAisles', aisle_info(system_of(system)))
          watch_all
          process_changes(false) # clear the new aisles in every bank they overlap
        end
      end

      @dlg.add_action_callback('remove_aisles') do |_c, system|
        guarded.call do
          unmark_aisles(Sketchup.active_model, false)
          push('onAisles', aisle_info(system_of(system)))
          watch_all
          process_changes(false)
        end
      end

      @dlg.add_action_callback('clear_aisles') do |_c, _a|
        guarded.call do
          unmark_aisles(Sketchup.active_model, true)
          push('onAisles', nil)
          watch_all
          process_changes(false)
        end
      end

      @dlg.add_action_callback('ignore_objects') do |_c, on|
        guarded.call do
          set_ignored(Sketchup.active_model, on.to_s == 'true')
          refresh_all
        end
      end

      @dlg.add_action_callback('refresh_all') do |_c, _a|
        guarded.call { refresh_all }
      end

      @dlg.add_action_callback('pick_focal') do |_c, system|
        sys = system_of(system)
        model = Sketchup.active_model
        model.select_tool(PointPicker.new do |pt|
          local = model.edit_transform.inverse * pt
          cur.focal = [local.x.to_f, local.y.to_f]
          push('onFocal', { text: "X #{Units.len(cur.focal[0], sys)}, Y #{Units.len(cur.focal[1], sys)}" })
        end)
      end

      @dlg.add_action_callback('clear_focal') do |_c, _a|
        cur.focal = nil
        push('onFocal', nil)
      end

      @dlg.add_action_callback('generate') do |_c, json|
        push('onBusy', true)
        UI.start_timer(0.15, false) do
          begin
            run_generate(JSON.parse(json))
          rescue StandardError => e
            push('onError', e.message)
            puts "#{StageForge.tag} seating error: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
          ensure
            push('onBusy', false)
          end
        end
      end

      @dlg.add_action_callback('export_csv') do |_c, _a|
        export_csv
      end

      @dlg.show
    end

    # ---------------- generation ----------------
    # Place (or replace) the bank being edited, from the dialog.
    def self.run_generate(s)
      bank = cur
      model = Sketchup.active_model
      unless bank_boundary(bank, model)
        b = read_area(model)
        bank.boundary = b
        bank.boundary_pid = pid_of(b[:src])
        bank.boundary_edges = b[:edge_pids]
      end
      lay_out(bank, s, live: false, transparent: false)
      watch_all
    end

    # Re-lays only the bank being edited with its stored settings (used when a dialog setting
    # changes while automatic updates are on).
    def self.relayout_current
      @busy = true
      begin
        push('onLive', 'working')
        lay_out(cur, cur.params, live: true, transparent: false)
        push_banks
      ensure
        @busy = false
        watch_all
      end
    end

    # Obstacle settings of a bank, in inches: nil when avoidance is off.
    def self.obstacle_ctx(bank, b, s, height)
      return nil if s['avoid'] == false
      system = system_of(s['units'])
      to_in = system == 'metric' ? 1.0 / 25.4 : 1.0
      lo = s['avoid_lo'].nil? ? Obstacles::DEFAULT_LO : s['avoid_lo'].to_f * to_in
      hi = s['avoid_hi'].nil? ? Obstacles::DEFAULT_HI : s['avoid_hi'].to_f * to_in
      hi = lo + 1.0 if hi <= lo
      { z0: b[:z], lo: lo, hi: hi, area: b[:bb], gap: [s['avoid_gap'].to_f * to_in, 0.0].max, height: height }
    end

    def self.obstacle_skip(b)
      (@banks.map { |bk| bk.boundary && bk.boundary[:src] }.compact + [b[:src]]).uniq
    end

    # Objects near these contexts (one model walk serves every bank).
    def self.gather_objects(model, ctxs, skips)
      return [] if ctxs.empty?
      g = ctxs.map { |c| c[:gap] }.max
      a = ctxs.map { |c| c[:area] }
      area = [a.map { |x| x[0] }.min - g, a.map { |x| x[1] }.min - g, a.map { |x| x[2] }.max + g, a.map { |x| x[3] }.max + g]
      Obstacles.gather(model, area, skips)
    end

    # Everything in the model that should keep chairs out (see Obstacles): returns regions for
    # the layout plus a summary { count:, names:, big: } for the result notes.
    def self.obstacle_regions(bank, b, s, height)
      ctx = obstacle_ctx(bank, b, s, height)
      unless ctx
        @obs_sigs[bank.id] = []
        return [[], { count: 0, names: [], big: [] }]
      end
      objs = gather_objects(Sketchup.active_model, [ctx], obstacle_skip(b))
      found = Obstacles.for_bank(objs, ctx)
      @obs_sigs[bank.id] = Obstacles.signature(found)
      regions = []
      big = []
      area = b[:area].to_f
      found.each do |o|
        o[:polys].each { |poly| regions << Packer::Region.new(poly, []) }
        cover = o[:polys].map { |poly| Packer.polygon_area(poly) }.sum
        big << o[:name] if area > 0 && cover / area > 0.5
      end
      [regions, { count: found.size, names: found.map { |o| o[:name] }.uniq.first(5), big: big.uniq }]
    end

    # Banks whose obstacles changed (something moved in or out of the avoided height band).
    def self.banks_with_moved_obstacles(model, banks)
      todo = banks.map do |bk|
        b = bank_boundary(bk, model)
        tables = bk.params && bk.params['kind'] == 'tables'
        next unless b && (tables || (bk.chair && bk.chair[:defn].valid?))
        height = tables ? TABLE_HEIGHT : [(bk.chair[:maxz] - bk.chair[:minz]) * bk.chair[:sz], 1.0].max
        ctx = obstacle_ctx(bk, b, bk.params, height)
        ctx && [bk, b, ctx]
      end.compact
      return [] if todo.empty?
      objs = gather_objects(model, todo.map { |t| t[2] }, todo.flat_map { |t| obstacle_skip(t[1]) }.uniq)
      todo.select do |bk, _b, ctx|
        sig = Obstacles.signature(Obstacles.for_bank(objs, ctx))
        prev = @obs_sigs[bk.id]
        @obs_sigs[bk.id] = sig if prev.nil?
        !prev.nil? && prev != sig
      end.map(&:first)
    end

    # Lays out one bank and rebuilds its group. s are the dialog settings.
    def self.lay_out(bank, s, live:, transparent:)
      return lay_out_tables(bank, s, live: live, transparent: transparent) if s['kind'] == 'tables'
      started = Time.now
      model = Sketchup.active_model
      b = bank_boundary(bank, model)
      raise 'The seating area is no longer in the model. Pick it again.' unless b
      show = s['show'] == 'boxes' ? 'boxes' : 'chair'
      c = bank.chair
      raise 'Pick the chair first (select it in the model, then "Use selected component").' unless c && c[:defn].valid?
      system = system_of(s['units'])
      to_in = system == 'metric' ? 1.0 / 25.4 : 1.0
      mode = %w[equal offset curved].include?(s['mode']) ? s['mode'] : 'equal'
      side = s['side'].to_f * to_in
      rowp = s['row'].to_f * to_in
      raise 'Side-to-side pitch must be greater than zero.' unless side > 0
      raise 'Front-to-front pitch must be greater than zero.' unless rowp > 0
      clearance = [s['clearance'].to_f * to_in, 0.0].max
      margin = [s['margin'].to_f * to_in, 0.0].max
      face_vec = FACING[s['facing']] || FACING['+x']

      wx = (c[:maxx] - c[:minx]) * c[:sx]
      wy = (c[:maxy] - c[:miny]) * c[:sy]
      facing_x = face_vec[0].abs > 0.5
      len = facing_x ? wx : wy # depth along the facing direction
      wid = facing_x ? wy : wx # width across it

      centroid = Seating.centroid(b[:outer])
      aisles = aisle_regions
      height = (c[:maxz] - c[:minz]) * c[:sz]
      obstacles, obs = obstacle_regions(bank, b, s, [height, 1.0].max)
      prm = { aisles: aisles + obstacles, side: side, row: rowp, len: len, wid: wid, clearance: clearance, margin: margin,
              align: s['align'] == 'best' ? 'best' : 'center', stagger: s['stagger'] ? true : false }
      front = nil
      if mode == 'curved'
        source = s['focal_source'].to_s
        r0 = s['radius'].to_s.empty? || s['radius'].nil? ? nil : s['radius'].to_f * to_in
        case source
        when 'front'
          front = resolve_front(bank, centroid)
          r0 ||= 315.0 # about 8 m
          raise 'The front-row radius is too small for this chair.' if r0 <= len / 2.0
          base = [front[:mid][0] - front[:f][0] * (clearance + len / 2.0),
                  front[:mid][1] - front[:f][1] * (clearance + len / 2.0)]
          focal = [base[0] + front[:f][0] * r0, base[1] + front[:f][1] * r0]
        when 'object'
          front = resolve_front(bank, centroid)
          raise 'Pick an object (not a line) as the front to use its centre as the focal point.' unless bank.front[:kind] == 'object'
          focal = front[:centre]
        else
          focal = bank.focal
          raise 'Pick the focal point in the model first.' unless focal
        end
        if r0.nil?
          d = Seating.min_dist_to_region(focal, b[:outer])
          inside = Packer.pip_state(focal, b[:outer]) != :out
          r0 = inside ? 118.0 : d + clearance + margin + len / 2.0
        end
        raise 'The front-row radius is too small for this chair.' if r0 <= len / 2.0
        prm[:focal] = focal
        prm[:r0] = r0
      else
        front = resolve_front(bank, centroid)
      end

      result = Seating.run(mode, b[:outer], b[:holes], front, prm)
      chairs = result[:chairs]
      if chairs.empty?
        hint = obs[:count] > 0 ? " #{obs[:count]} object(s) in the model are keeping chairs out (#{obs[:names].join(', ')}); untick avoidance or ignore them if they should not." : ''
        raise "No chairs fit. Check the boundary, the chair size and the pitches.#{hint}"
      end

      notes = result[:notes].dup
      if obs[:count] > 0
        notes << "Keeping clear of #{obs[:count]} object(s) in the model: #{obs[:names].join(', ')}" \
                 "#{obs[:count] > obs[:names].size ? ', \u2026' : ''}. Use \"Ignore selected objects\" for anything that should not block."
      end
      unless obs[:big].empty?
        notes << "#{obs[:big].join(', ')} covers most of this area, so it removes most chairs. " \
                 'If it is the floor or ground, select it and use "Ignore selected objects".'
      end
      bank.layout = { chairs: chairs, face_vec: face_vec, mode: mode, z0: b[:z], len: len, wid: wid,
                      height: [height, 1.0].max }
      bank.params = s.reject { |k, _| k.to_s.start_with?('_') }
      bank.chairs = chairs.size
      bank.mode = mode
      build(model, bank, show, transparent)
      @banks << bank unless @banks.include?(bank)
      @bank_sigs[bank.id] = poly_round(b[:outer])
      @aisle_sigs ||= aisle_poly_map

      per_row = result[:rows]
      if bank == cur
        @last = { rows: per_row, chairs: chairs.size, system: system, mode: mode }
        push('onResult', {
               chairs: chairs.size, rows: per_row.size,
               per_chair: Units.area(b[:area] / chairs.size, system),
               area: Units.area(b[:area], system),
               per_row: per_row.first(80), more: [per_row.size - 80, 0].max,
               notes: notes, mode: mode, aisles: aisles.size, show: show, live: live,
               seconds: format('%.1f', Time.now - started)
             })
      end
      push_banks unless live
    end

    TABLE_HEIGHT = 30.0 # inches (about 760 mm)
    DEFAULT_CHAIR = [17.7, 17.7, 35.4].freeze # inches: 450 x 450 x 900 mm stand-in chair

    # Table plan: round tables with seats round them. Settings come from the dialog in display
    # units (t_dia is always inches). Uses the picked chair's size when there is one.
    def self.lay_out_tables(bank, s, live:, transparent:)
      started = Time.now
      model = Sketchup.active_model
      b = bank_boundary(bank, model)
      raise 'The seating area is no longer in the model. Pick it again.' unless b
      show = s['show'] == 'boxes' ? 'boxes' : 'chair'
      c = bank.chair
      c = nil unless c && c[:defn].valid?
      system = system_of(s['units'])
      to_in = system == 'metric' ? 1.0 / 25.4 : 1.0
      face_vec = FACING[s['facing']] || FACING['+x']
      if c
        wx = (c[:maxx] - c[:minx]) * c[:sx]
        wy = (c[:maxy] - c[:miny]) * c[:sy]
        facing_x = face_vec[0].abs > 0.5
        clen = facing_x ? wx : wy
        cwid = facing_x ? wy : wx
        cheight = [(c[:maxz] - c[:minz]) * c[:sz], 1.0].max
      else
        clen, cwid, cheight = DEFAULT_CHAIR
      end
      dia = s['t_dia'].to_f
      raise 'Pick a table size.' unless dia > 0
      seats = s['t_seats'].to_i
      raise 'Seats per table must be at least 1.' unless seats >= 1
      arrangement = s['t_arr'] == 'horseshoe' ? 'horseshoe' : 'dining'
      layout = %w[inline staggered bestfit].include?(s['t_layout']) ? s['t_layout'] : 'inline'
      side = s['t_side'].to_f * to_in
      rowp = s['t_row'].to_f * to_in
      raise 'Table spacing must be greater than zero.' unless side > 0
      rowp = side unless rowp > 0
      clearance = [s['clearance'].to_f * to_in, 0.0].max
      margin = [s['margin'].to_f * to_in, 0.0].max
      aisles = aisle_regions
      tz = TABLE_HEIGHT
      obstacles, obs = obstacle_regions(bank, b, s, [[cheight, tz].max, 1.0].max)
      front = resolve_front(bank, Seating.centroid(b[:outer]))
      region = Packer::Region.new(b[:outer], b[:holes])
      prm = { arrangement: arrangement, layout: layout, dia: dia, seats: seats, side: side, row: rowp,
              clearance: clearance, margin: margin, chair_len: clen, chair_wid: cwid,
              align: s['align'] == 'best' ? 'best' : 'center', aisles: aisles + obstacles, max_seconds: 6.0 }
      result = Tables.run(region, b[:outer], front, prm)
      if result[:tables].empty?
        hint = obs[:count] > 0 ? " #{obs[:count]} object(s) in the model are keeping tables out (#{obs[:names].join(', ')})." : ''
        raise "No tables fit. Check the area, the table size and the spacing.#{hint}"
      end
      notes = result[:notes].dup
      if obs[:count] > 0
        notes << "Keeping clear of #{obs[:count]} object(s) in the model: #{obs[:names].join(', ')}."
      end
      unless obs[:big].empty?
        notes << "#{obs[:big].join(', ')} covers most of this area. If it is the floor or ground, select it and use \"Ignore selected objects\"."
      end
      tables = result[:tables]
      seat_list = result[:seats]
      bank.layout = { kind: 'tables', tables: tables, chairs: seat_list, face_vec: face_vec, mode: "#{arrangement} #{layout}",
                      z0: b[:z], len: clen, wid: cwid, height: cheight, dia: dia, table_height: tz }
      bank.params = s.reject { |k, _| k.to_s.start_with?('_') }
      bank.chairs = seat_list.size
      bank.tables = tables.size
      bank.mode = bank.layout[:mode]
      build(model, bank, show, transparent)
      @banks << bank unless @banks.include?(bank)
      @bank_sigs[bank.id] = poly_round(b[:outer])
      @aisle_sigs ||= aisle_poly_map
      if bank == cur
        rows = result[:rows]
        @last = { rows: rows, chairs: seat_list.size, tables: tables.size, system: system, mode: bank.mode, kind: 'tables' }
        push('onResult', {
               kind: 'tables', tables: tables.size, chairs: seat_list.size, rows: rows.size,
               per_chair: Units.area(b[:area] / seat_list.size, system),
               area: Units.area(b[:area], system),
               per_row: rows.first(80), more: [rows.size - 80, 0].max,
               notes: notes, mode: bank.mode, aisles: aisles.size, show: show, live: live,
               seconds: format('%.1f', Time.now - started)
             })
      end
      push_banks unless live
    end

    # A plain cylinder for a table top, origin at the centre on the floor.
    def self.table_definition(model, dia, height)
      name = "StageForge table #{(dia * 25.4).round}mm x #{(height * 25.4).round}mm"
      existing = model.definitions[name]
      return existing if existing && existing.valid?
      defn = model.definitions.add(name)
      ents = defn.entities
      circle = ents.add_circle(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), dia / 2.0, 48)
      face = ents.add_face(circle)
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      mat = Builder.material(model, :table)
      ents.grep(Sketchup::Face).each do |f|
        f.material = mat
        f.back_material = mat
      end
      defn
    end

    # A plain box the size of the chair's footprint, centred on its origin and facing +X
    # (the front face is a different colour). One shared definition serves every chair.
    def self.proxy_definition(model, len, wid, height)
      name = "StageForge chair proxy #{(len * 25.4).round}x#{(wid * 25.4).round}x#{(height * 25.4).round}mm"
      existing = model.definitions[name]
      return existing if existing && existing.valid?
      defn = model.definitions.add(name)
      ents = defn.entities
      hl = len / 2.0
      hw = wid / 2.0
      face = ents.add_face([-hl, -hw, 0], [hl, -hw, 0], [hl, hw, 0], [-hl, hw, 0])
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
      body = Builder.material(model, :proxy)
      front = Builder.material(model, :proxy_front)
      ents.grep(Sketchup::Face).each do |f|
        m = f.normal.x > 0.9 ? front : body
        f.material = m
        f.back_material = m
      end
      defn
    end

    def self.bank_payload(bank)
      c = bank.chair
      chair = c && c.reject { |k, _| k == :defn }.merge(defn: c[:defn].valid? ? c[:defn].name : nil)
      { id: bank.id, name: bank.name, params: bank.params, front: bank.front, focal: bank.focal,
        chair: chair, boundary: bank.boundary_pid, boundary_edges: bank.boundary_edges }
    end

    # Every seating group belonging to this bank, found by tag rather than by remembered
    # reference, so none is left behind to overlap the new one.
    def self.tagged_groups(model, bank)
      model.active_entities.grep(Sketchup::Group).select do |g|
        g.valid? && g.get_attribute(TAG, 'set_id') == bank.id
      end
    end

    # Replaces the bank's seating group, all in one undo step. A live update joins the user's
    # own edit (transparent) so one Undo reverts both.
    def self.build(model, bank, show, transparent = false)
      layout = bank.layout
      chairs = layout[:chairs]
      z0 = layout[:z0]
      model.start_operation('StageForge: place seating', true, false, transparent)
      begin
        old = tagged_groups(model, bank)
        old << bank.group if bank.group && bank.group.valid? && !old.include?(bank.group)
        old.each { |o| o.erase! if o.valid? }
        grp = model.active_entities.add_group
        if layout[:kind] == 'tables'
          grp.name = "#{bank.name} - #{layout[:tables].size} tables, #{chairs.size} chairs (#{layout[:mode]})"
        else
          grp.name = "#{bank.name} - #{chairs.size} chairs (#{layout[:mode]}, #{show == 'boxes' ? 'boxes' : 'chairs'})"
        end
        origin = Geom::Point3d.new(0, 0, 0)
        zaxis = Geom::Vector3d.new(0, 0, 1)
        if layout[:kind] == 'tables'
          tdef = table_definition(model, layout[:dia], layout[:table_height])
          layout[:tables].each do |tb|
            grp.entities.add_instance(tdef, Geom::Transformation.new(Geom::Point3d.new(tb.x, tb.y, z0)))
          end
        end
        if show == 'boxes' || (layout[:kind] == 'tables' && !(bank.chair && bank.chair[:defn].valid?))
          defn = proxy_definition(model, layout[:len], layout[:wid], layout[:height])
          chairs.each do |ch|
            tr = Geom::Transformation.new(Geom::Point3d.new(ch.x, ch.y, z0)) *
                 Geom::Transformation.rotation(origin, zaxis, Math.atan2(ch.dy, ch.dx))
            grp.entities.add_instance(defn, tr)
          end
        else
          c = bank.chair
          cx = (c[:minx] + c[:maxx]) / 2.0
          cy = (c[:miny] + c[:maxy]) / 2.0
          a0 = Math.atan2(layout[:face_vec][1], layout[:face_vec][0])
          undo_c = Geom::Transformation.new(Geom::Point3d.new(-cx, -cy, 0))
          scale = Geom::Transformation.scaling(c[:sx], c[:sy], c[:sz])
          chairs.each do |ch|
            theta = Math.atan2(ch.dy, ch.dx) - a0
            tr = Geom::Transformation.new(Geom::Point3d.new(ch.x, ch.y, z0)) *
                 Geom::Transformation.rotation(origin, zaxis, theta) * scale * undo_c
            grp.entities.add_instance(c[:defn], tr)
          end
        end
        bank.group = grp
        grp.set_attribute(TAG, 'set_id', bank.id)
        grp.set_attribute(TAG, 'seating', JSON.generate(bank_payload(bank)))
        unless transparent
          model.selection.clear
          model.selection.add(grp)
        end
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
    end

    # Swaps every bank between boxes and the real chair, without recalculating where possible.
    def self.show_all(show)
      model = Sketchup.active_model
      @banks.each do |bk|
        next unless bk.params
        bk.params = bk.params.merge('show' => show)
        tables = bk.params['kind'] == 'tables'
        if bk.layout && (tables || (bk.chair && bk.chair[:defn].valid?))
          build(model, bk, show, false)
        elsif tables || (bk.chair && bk.chair[:defn].valid?)
          begin
            lay_out(bk, bk.params, live: true, transparent: false)
          rescue StandardError => e
            push('onError', "#{bk.name}: #{e.message}")
          end
        end
      end
      push_banks
      push('onShown', show)
    end

    def self.export_csv
      r = @last
      return UI.messagebox('Generate a seating plan first.') unless r
      path = UI.savepanel('Export seating counts', nil, 'StageForge seating.csv')
      return unless path
      path += '.csv' unless path.downcase.end_with?('.csv')
      CSV.open(path, 'w', encoding: 'UTF-8') do |csv|
        if r[:kind] == 'tables'
          csv << %w[Row Tables Guests]
          r[:rows].each { |x| csv << [x[:row], x[:tables], x[:count]] }
          csv << []
          csv << ['Total tables', r[:tables]]
          csv << ['Total guests', r[:chairs]]
        else
          csv << %w[Row Chairs]
          r[:rows].each { |x| csv << [x[:row], x[:count]] }
          csv << []
          csv << ['Total chairs', r[:chairs]]
        end
        csv << ['Layout', r[:mode]]
      end
      UI.messagebox("Saved:\n#{path}")
    end
  end
end
