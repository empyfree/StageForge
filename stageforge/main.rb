# frozen_string_literal: true

require 'sketchup.rb'
require 'json'
require 'csv'

module StageForge
  DIR = File.dirname(__FILE__)
  PREF_KEY = 'StageForge'

  require File.join(DIR, 'packer')
  require File.join(DIR, 'catalog')
  require File.join(DIR, 'perimeter')
  require File.join(DIR, 'tiers')
  require File.join(DIR, 'builder')
  require File.join(DIR, 'seating')
  require File.join(DIR, 'obstacles')
  require File.join(DIR, 'tables')
  require File.join(DIR, 'seating_ui')
  require File.join(DIR, 'planner')

  EFFORT = {
    'fast' => { max_seconds: 6, angle_count: 2, offset_n: 1, finalists: 1 },
    'normal' => { max_seconds: 20, angle_count: 4, offset_n: 3, finalists: 3 },
    'thorough' => { max_seconds: 60, angle_count: 6, offset_n: 5, finalists: 4 }
  }.freeze

  @dlg = nil
  @catalog = nil
  @boundary = nil
  @last_report = nil
  @tier_edges = []

  # ------------------------------------------------------------------
  # Reading the model: faces, groups and components
  # ------------------------------------------------------------------
  def self.clean_loop(pts)
    out = []
    pts.each do |p|
      out << p if out.empty? || Math.hypot(p[0] - out.last[0], p[1] - out.last[1]) > Packer::EPS
    end
    out.pop if out.size > 1 && Math.hypot(out.first[0] - out.last[0], out.first[1] - out.last[1]) <= Packer::EPS
    out
  end

  # Every face in a face / group / component (recursively) with the transformation that
  # takes it into the current editing context.
  def self.faces_of(entity, t = Geom::Transformation.new)
    out = []
    if entity.is_a?(Sketchup::Face)
      out << [entity, t]
    elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      tt = t * entity.transformation
      entity.definition.entities.each { |e| out.concat(faces_of(e, tt)) }
    end
    out
  end

  def self.horizontal_faces(entity)
    faces_of(entity).select do |f, t|
      n = t * f.normal
      l = n.length
      l > 1e-9 && (n.z / l).abs > 0.999
    end
  end

  def self.face_polygon(face, t)
    xy = lambda do |lp|
      clean_loop(lp.vertices.map { |v| p = t * v.position; [p.x.to_f, p.y.to_f] })
    end
    outer = xy.call(face.outer_loop)
    holes = (face.loops - [face.outer_loop]).map { |l| xy.call(l) }.select { |h| h.size >= 3 }
    zs = face.outer_loop.vertices.map { |v| (t * v.position).z.to_f }
    outer.reverse! if outer.size >= 3 && Packer.signed_area(outer) < 0
    { outer: outer, holes: holes, z: zs.sum / zs.size }
  end

  def self.read_boundary(model)
    sel = model.selection
    cands = [] # [face, transformation, source entity]
    loose = sel.grep(Sketchup::Face)
    if loose.any?
      loose.each { |f| cands << [f, Geom::Transformation.new, f] }
      return @boundary = pick_boundary(cands)
    end
    containers = sel.select { |e| e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance) }
    containers.each do |c|
      horizontal_faces(c).each { |f, t| cands << [f, t, c] }
    end
    return @boundary = pick_boundary(cands) unless cands.empty?
    # No faces: a closed set of lines (no face needed, none is created), loose or in a group.
    edges = sel.grep(Sketchup::Edge)
    return @boundary = boundary_from_edges(edges) unless edges.empty?
    containers.each do |c|
      b = (boundary_from_source(c) rescue nil)
      return @boundary = b if b
    end
    raise 'Select a flat face, a closed set of lines, or a group/component containing either, ' \
          'to use as the boundary.'
  end

  # ---- areas defined by lines only ----
  # The selected edges must form one or more closed loops (a loop inside another is a cut-out).
  def self.loops_from_edges(edges, tr = Geom::Transformation.new)
    edges = edges.select { |e| e.is_a?(Sketchup::Edge) && e.valid? }.uniq
    raise 'No lines selected.' if edges.empty?
    adj = Hash.new { |h, k| h[k] = [] }
    verts = {}
    edges.each do |e|
      [e.start, e.end].each do |v|
        adj[v.entityID] << e
        verts[v.entityID] = v
      end
    end
    unless adj.values.all? { |es| es.size == 2 }
      raise 'The lines do not form a closed loop: a line end is open, or lines branch or touch at a point. ' \
            'Select only the lines that enclose the area.'
    end
    remaining = edges.dup
    loops = []
    until remaining.empty?
      first = remaining.shift
      v0 = first.start
      pts = [v0]
      v = first.end
      cur = first
      guard = 0
      while v.entityID != v0.entityID
        pts << v
        nxt = adj[v.entityID].find { |x| x.entityID != cur.entityID }
        raise 'The lines do not form a closed loop.' unless nxt
        remaining.delete(nxt)
        v = nxt.start.entityID == v.entityID ? nxt.end : nxt.start
        cur = nxt
        guard += 1
        raise 'The lines do not form a closed loop.' if guard > edges.size + 2
      end
      loops << pts.map { |vx| tr * vx.position }
    end
    loops
  end

  def self.boundary_from_edges(edges, tr = Geom::Transformation.new, src = nil)
    loops = loops_from_edges(edges, tr).map do |pts3|
      zs = pts3.map(&:z)
      raise 'The lines must lie flat (all at the same height).' if zs.max - zs.min > 0.1
      xy = clean_loop(pts3.map { |p| [p.x.to_f, p.y.to_f] })
      { xy: xy, z: zs.sum / zs.size, area: Packer.signed_area(xy) }
    end.select { |l| l[:xy].size >= 3 && l[:area].abs > 1e-6 }
    raise 'The lines do not enclose any area.' if loops.empty?
    outer = loops.max_by { |l| l[:area].abs }
    holes = (loops - [outer]).map { |l| l[:xy] }
    ox = outer[:xy]
    ox = ox.reverse if outer[:area] < 0
    area = outer[:area].abs - holes.map { |h| Packer.polygon_area(h) }.sum
    {
      src: src || edges.first, edges: edges, edge_pids: edges.map { |e| e.persistent_id },
      outer: ox, holes: holes, z: outer[:z], bb: Packer.bbox(ox), area: area
    }
  end

  # All lines of a group/component (top level), for an area drawn with lines only.
  def self.group_edges(c)
    ents = c.is_a?(Sketchup::Group) ? c.entities : c.definition.entities
    [ents.grep(Sketchup::Edge), c.transformation]
  end

  # Walks from one line round the loop it belongs to (clean loops only).
  def self.connected_loop(start)
    edges = [start]
    queue = [start]
    until queue.empty?
      e = queue.shift
      [e.start, e.end].each do |v|
        others = v.edges
        raise 'The lines at this area no longer form a clean closed loop.' unless others.size == 2
        others.each do |o|
          next if edges.any? { |x| x.entityID == o.entityID }
          edges << o
          queue << o
        end
      end
    end
    edges
  end

  # Largest horizontal face among [face, transformation, source] candidates.
  def self.pick_boundary(cands)
    best = nil
    cands.each do |f, t, src|
      n = t * f.normal
      next unless n.length > 1e-9 && (n.z / n.length).abs > 0.999
      poly = face_polygon(f, t)
      next if poly[:outer].size < 3
      area = Packer.polygon_area(poly[:outer]) - poly[:holes].map { |h| Packer.polygon_area(h) }.sum
      best = { poly: poly, area: area, src: src } if best.nil? || area > best[:area]
    end
    raise 'No horizontal face found. The boundary must lie flat (parallel to the ground).' unless best
    poly = best[:poly]
    {
      src: best[:src], outer: poly[:outer], holes: poly[:holes], z: poly[:z],
      bb: Packer.bbox(poly[:outer]), area: best[:area]
    }
  end

  # Re-reads the current boundary from the entity it came from (it may have been moved or
  # edited), without looking at the selection. Used by live seating updates.
  def self.refresh_boundary
    b = @boundary
    raise 'The seating area is no longer in the model. Pick it again.' unless b && b[:src] && b[:src].valid?
    @boundary = boundary_from_source(b[:src], b[:edge_pids])
  end

  # Boundary of an existing face/group/component/line, without looking at the selection and
  # without touching the stage tool's current boundary (seating banks each keep their own).
  # edge_pids: persistent ids of the lines when the area was drawn with lines only.
  def self.boundary_from_source(src, edge_pids = nil, model = nil)
    if src.is_a?(Sketchup::Edge)
      m = model || Sketchup.active_model
      edges = if edge_pids && m.respond_to?(:find_entity_by_persistent_id)
                found = edge_pids.map { |pid| m.find_entity_by_persistent_id(pid) }
                found.all? { |e| e && e.valid? } ? found : nil
              end
      edges ||= connected_loop(src)
      return boundary_from_edges(edges, Geom::Transformation.new, src)
    end
    cands = if src.is_a?(Sketchup::Face)
              [[src, Geom::Transformation.new, src]]
            else
              horizontal_faces(src).map { |f, t| [f, t, src] }
            end
    return pick_boundary(cands) unless cands.empty?
    if src.is_a?(Sketchup::Group) || src.is_a?(Sketchup::ComponentInstance)
      edges, tr = group_edges(src)
      return boundary_from_edges(edges, tr, src)
    end
    pick_boundary(cands)
  end

  def self.use_boundary_source(src)
    @boundary = boundary_from_source(src)
  end

  def self.boundary=(b)
    @boundary = b
  end

  # If the boundary entity was replaced (undo/redo gives new objects), find it again by its
  # persistent id.
  def self.reacquire_boundary(model, pid)
    b = @boundary
    return true if b && b[:src] && b[:src].valid?
    return false unless pid && model.respond_to?(:find_entity_by_persistent_id)
    e = model.find_entity_by_persistent_id(pid)
    return false unless e && e.valid?
    use_boundary_source(e)
    true
  rescue StandardError
    false
  end

  def self.boundary
    @boundary
  end

  def self.current_boundary(model)
    b = @boundary
    return b if b && b[:src] && b[:src].valid?
    read_boundary(model)
  end

  # ------------------------------------------------------------------
  # Tiered-step edges
  # ------------------------------------------------------------------
  def self.add_tier_edge(p1, p2)
    return false if Math.hypot(p2[0] - p1[0], p2[1] - p1[1]) < Packer::EPS
    key = ->(a, b) { [[a[0].round(1), a[1].round(1)], [b[0].round(1), b[1].round(1)]].sort }
    k = key.call(p1, p2)
    return false if @tier_edges.any? { |e| key.call(e[0], e[1]) == k }
    @tier_edges << [p1, p2]
    true
  end

  def self.tier_info(system)
    return nil if @tier_edges.empty?
    total = @tier_edges.map { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) }.sum
    { count: @tier_edges.size, length: Units.len(total, system) }
  end

  # Click near a boundary edge to mark it as a tiered-step edge. Stays active until Esc.
  class TierPicker
    def initialize(&callback)
      @callback = callback
      @ip = Sketchup::InputPoint.new
      @hover = nil
      @b = StageForge.current_boundary(Sketchup.active_model)
    end

    def activate
      Sketchup.status_text = 'Click a boundary edge to make it a tiered-step edge. Esc to finish.'
    end

    def deactivate(view)
      view.invalidate
    end

    def nearest(pt)
      local = Sketchup.active_model.edit_transform.inverse * pt
      q = [local.x.to_f, local.y.to_f]
      outer = @b[:outer]
      best = nil
      bd = Float::INFINITY
      outer.each_index do |i|
        a = outer[i]
        c = outer[(i + 1) % outer.size]
        d = Packer.dist_pt_seg(q, a, c)
        if d < bd
          bd = d
          best = [a, c]
        end
      end
      best
    end

    def onMouseMove(_flags, x, y, view)
      @ip.pick(view, x, y)
      @hover = nearest(@ip.position)
      view.invalidate
    end

    def onLButtonDown(_flags, x, y, view)
      @ip.pick(view, x, y)
      seg = nearest(@ip.position)
      @callback.call(seg) if seg
      view.invalidate
    end

    def onCancel(_reason, _view)
      Sketchup.active_model.select_tool(nil)
    end

    def draw(view)
      return unless @hover
      et = Sketchup.active_model.edit_transform
      z = @b[:z]
      view.line_width = 5
      view.drawing_color = Sketchup::Color.new(230, 140, 20)
      view.draw_lines(et * Geom::Point3d.new(@hover[0][0], @hover[0][1], z),
                      et * Geom::Point3d.new(@hover[1][0], @hover[1][1], z))
    end
  end

  # ------------------------------------------------------------------
  # Dialog plumbing
  # ------------------------------------------------------------------
  def self.push(fn, obj = nil)
    return unless @dlg
    arg = obj.nil? ? '' : JSON.generate(obj)
    @dlg.execute_script("SF.#{fn}(#{arg})")
  end

  def self.read_pref(key)
    raw = Sketchup.read_default(PREF_KEY, key, '')
    raw.to_s.empty? ? {} : JSON.parse(raw)
  rescue StandardError
    {}
  end

  def self.boundary_info(b, system)
    w = b[:bb][2] - b[:bb][0]
    h = b[:bb][3] - b[:bb][1]
    {
      corners: b[:outer].size, holes: b[:holes].size,
      area: Units.area(b[:area], system),
      size: "#{Units.len(w, system)} \u00D7 #{Units.len(h, system)} (bounding box)"
    }
  end

  # Display units (what the person types and reads) are independent of the deck system.
  def self.display
    @display ||= (read_pref('state')['display'] == 'imperial' ? 'imperial' : 'metric')
  end

  def self.system_for_ui
    display
  end

  # Kept for the many call sites that pass a unit argument: the display setting always wins.
  def self.sys(_arg = nil)
    display
  end

  def self.tag
    "StageForge v#{VERSION}"
  end

  def self.show_dialog
    if @dlg && @dlg.visible?
      @dlg.bring_to_front
      return
    end
    @dlg = UI::HtmlDialog.new(
      dialog_title: "StageForge v#{VERSION}", preferences_key: 'StageForge.Main', scrollable: true,
      resizable: true, width: 1020, height: 860, min_width: 780, min_height: 560,
      style: UI::HtmlDialog::STYLE_DIALOG
    )
    @dlg.set_file(File.join(DIR, 'html', 'dialog.html'))

    guarded = lambda do |&blk|
      begin
        blk.call
      rescue StandardError => e
        push('onError', e.message)
        puts "#{tag} error: #{e.message}"
      end
    end

    @dlg.add_action_callback('set_display') do |_c, arg|
      @display = arg.to_s == 'imperial' ? 'imperial' : 'metric'
      push('onTiers', tier_info(@display))
      push('onBoundary', @boundary ? boundary_info(@boundary, @display) : nil)
    end

    @dlg.add_action_callback('ready') do |_c, _a|
      begin
        @catalog = Catalog.load
        push('init', { catalog: @catalog, state: read_pref('state'), library: read_pref('library'), version: VERSION })
        push('onTiers', tier_info(system_for_ui))
        begin
          read_boundary(Sketchup.active_model)
          push('onBoundary', boundary_info(@boundary, system_for_ui))
        rescue StandardError
          nil
        end
      rescue StandardError => e
        push('onError', "Could not start: #{e.message}")
      end
    end

    @dlg.add_action_callback('save_state') do |_c, json|
      Sketchup.write_default(PREF_KEY, 'state', json.to_s)
    end

    @dlg.add_action_callback('save_library') do |_c, json|
      Sketchup.write_default(PREF_KEY, 'library', json.to_s)
      push('onLibrarySaved')
    end

    @dlg.add_action_callback('use_selection') do |_c, system|
      guarded.call do
        begin
          read_boundary(Sketchup.active_model)
        rescue StandardError
          @boundary = nil
          push('onBoundary', nil)
          raise
        end
        push('onBoundary', boundary_info(@boundary, sys(system)))
      end
    end

    @dlg.add_action_callback('draw_tool') do |_c, name|
      actions = {
        'rect' => 'selectRectangleTool:', 'line' => 'selectLineTool:', 'arc' => 'selectArcTool:',
        'circle' => 'selectCircleTool:', 'polygon' => 'selectPolygonTool:'
      }
      act = actions[name.to_s]
      Sketchup.send_action(act) if act
    end

    @dlg.add_action_callback('pick_tier_edge') do |_c, system|
      guarded.call do
        s = sys(system)
        Sketchup.active_model.select_tool(TierPicker.new do |seg|
          add_tier_edge(seg[0], seg[1])
          push('onTiers', tier_info(s))
        end)
      end
    end

    @dlg.add_action_callback('add_tier_selected') do |_c, system|
      guarded.call do
        edges = Sketchup.active_model.selection.grep(Sketchup::Edge)
        raise 'Select one or more straight edges first (for example an edge of the boundary face).' if edges.empty?
        edges.each do |e|
          a = e.start.position
          b = e.end.position
          add_tier_edge([a.x.to_f, a.y.to_f], [b.x.to_f, b.y.to_f])
        end
        push('onTiers', tier_info(sys(system)))
      end
    end

    @dlg.add_action_callback('clear_tiers') do |_c, _a|
      @tier_edges = []
      push('onTiers', nil)
    end

    @dlg.add_action_callback('generate') do |_c, json|
      push('onBusy', true)
      UI.start_timer(0.15, false) do
        begin
          run_generate(JSON.parse(json))
        rescue StandardError => e
          push('onError', e.message)
          puts "#{tag} error: #{e.message}\n#{e.backtrace.first(8).join("\n")}"
        ensure
          push('onBusy', false)
        end
      end
    end

    @dlg.add_action_callback('export_csv') do |_c, _a|
      export_csv
    end

    @dlg.add_action_callback('edit_catalog') do |_c, _a|
      dir = Catalog.ensure_user_file
      UI.openURL("file:///#{dir.tr('\\', '/').sub(%r{\A/}, '')}")
    end

    @dlg.add_action_callback('reload_catalog') do |_c, _a|
      @catalog = Catalog.load
      push('init', { catalog: @catalog, state: read_pref('state'), library: read_pref('library'), version: VERSION })
    end

    @dlg.show
  end

  # ------------------------------------------------------------------
  # Generation
  # ------------------------------------------------------------------
  def self.run_generate(s)
    model = Sketchup.active_model
    b = current_boundary(model)
    @catalog ||= Catalog.load
    found = Catalog.find_model(@catalog, s['model'])
    raise 'Unknown staging model - pick a make and model.' unless found
    make, md = found
    system = s['display'] == 'imperial' ? 'imperial' : 'metric' # display units for reports
    @display = system
    to_in = md['dim_unit'] == 'mm' ? 1.0 / 25.4 : 1.0 # catalog dimensions -> inches
    enabled = Array(s['enabled'])
    pieces = md['blocks'].select { |bk| enabled.include?(bk['id']) }.map { |bk| Packer.build_piece(bk, to_in) }
    raise 'Tick at least one block in the library.' if pieces.empty?

    height = s['height'].to_f # inches
    raise 'Enter a finished stage height greater than zero.' unless height > 0
    fascia = %w[hard soft].include?(s['fascia']) ? s['fascia'] : 'none'
    style = s['style'] == 'legs' ? 'legs' : 'solid'
    effort = (EFFORT[s['effort']] || EFFORT['normal']).dup
    rects = pieces.select(&:rect)
    default_deck = rects.find { |p| p.id == s['default_deck'] } || rects.max_by(&:area)
    ded_default = (md['leg_deduction'] || md['deck_thickness'] || (md['dim_unit'] == 'mm' ? 25 : 1)).to_f * to_in
    deduction = s['leg_deduction'].nil? ? ded_default : s['leg_deduction'].to_f
    raise 'The leg length deduction must be zero or more, and less than the stage height.' unless deduction >= 0 && deduction < height

    plan = Planner.plan(
      b[:outer], b[:holes], pieces,
      height: height, fascia: fascia, effort: effort, system: system,
      tier_edges: @tier_edges, inside: s['tier_inside'] ? true : false,
      overlap: s['tier_overlap'].nil? ? nil : s['tier_overlap'].to_f,
      rise_target: s['tier_rise'].nil? ? (system == 'metric' ? 200.0 / 25.4 : 8.0) : s['tier_rise'].to_f,
      steps: s['tier_steps'].nil? ? nil : s['tier_steps'].to_i,
      default_deck: default_deck
    )
    placed = plan[:placed]
    tiers = plan[:tiers]
    paths = plan[:paths]
    result = plan[:result]
    stage_area = plan[:stage_area]

    meta = { make: make['name'], model: md['name'], units: md['units'], height: height,
             fascia: fascia, style: style, blocks: enabled, steps: plan[:steps],
             steps_inside: s['tier_inside'] ? true : false, leg_deduction: deduction }
    prm = {
      height: height, style: style, fascia: fascia,
      deck_thickness: deduction,
      leg_size: (md['leg_size'] || 2).to_f * to_in,
      hard_t: (md['hard_fascia_thickness'] || 0.75).to_f * to_in,
      pitch: (md['soft_pleat_pitch'] || 6).to_f * to_in,
      name: "Stage - #{make['name']} #{md['name']} - #{Units.len(height, system)}",
      meta: meta, tiers: tiers ? tiers[:tiers] : [], paths: paths
    }
    _stage, tally = Builder.build(model, b, placed, prm)

    # ---- report ----
    rows = placed.group_by { |pl| pl.piece.id }.map do |_id, list|
      pc = list.first.piece
      { name: pc.name, dims: pc.label, qty: list.size, area: Units.area(pc.area * list.size, system),
        raw_area: pc.area * list.size }
    end
    rows.sort_by! { |r| -r[:raw_area] }
    tier_blocks = 0
    step_area = 0.0
    if tiers
      all = tiers[:tiers].flat_map { |t| t[:placed] }
      tier_blocks = all.size
      step_area = all.map(&:area).sum
      all.group_by { |pl| pl.piece.id }.each do |_id, list|
        pc = list.first.piece
        rows << { name: "#{pc.name} (steps)", dims: pc.label, qty: list.size,
                  area: Units.area(pc.area * list.size, system), raw_area: 0 }
      end
    end

    perim = 0.0
    loops = paths.empty? ? [{ pts: plan[:stage_outer], closed: true }] : paths
    loops.each do |pa|
      pts = pa[:pts]
      (pa[:closed] ? pts.size : pts.size - 1).times do |i|
        q = pts[(i + 1) % pts.size]
        perim += Math.hypot(q[0] - pts[i][0], q[1] - pts[i][1])
      end
    end

    legs = tally.map { |(len, bearing), count| { len: len, bearing: bearing, count: count } }
    legs.sort_by! { |l| [l[:bearing] ? 1 : 0, -l[:len]] }
    leg_rows = legs.map do |l|
      { length: Units.len(l[:len], system), qty: l[:count],
        kind: l[:bearing] ? 'Bearing on the deck below' : 'Ground-reaching' }
    end

    covered = result[:covered_area]
    pct = stage_area > 0 ? (covered / stage_area * 100.0) : 0.0
    @last_report = {
      rows: rows.map { |r| r.reject { |k, _| k == :raw_area } },
      total_blocks: placed.size + tier_blocks,
      covered: Units.area(covered, system),
      boundary: Units.area(stage_area, system),
      uncovered: Units.area([stage_area - covered, 0].max, system),
      coverage: format('%.1f', pct),
      perimeter: Units.len(perim, system),
      fascia: fascia, seconds: format('%.1f', result[:seconds].to_f),
      stage: prm[:name],
      version: VERSION,
      quote: quote_line(plan, placed, make, md, system),
      steps: plan[:steps],
      suggested: plan[:suggested],
      inside: s['tier_inside'] ? true : false,
      rise: plan[:rise] ? Units.len(plan[:rise], system) : nil,
      step_area: step_area > 0 ? Units.area(step_area, system) : nil,
      legs: leg_rows, total_legs: legs.map { |l| l[:count] }.sum,
      leg_deduction: Units.len(deduction, system),
      notes: plan[:notes]
    }
    push('onResult', @last_report)
  end

  # "28' x 12' (8.53 m x 3.66 m) of 8' x 4' decks": the decked platform in both systems.
  def self.quote_line(plan, placed, make, md, _system)
    fp = plan[:footprint]
    return nil unless fp && fp[:w] > 0
    rect = placed.select { |pl| pl.piece.rect }.group_by { |pl| pl.piece.id }.max_by { |_i, l| l.size }
    deck = rect ? " of #{rect[1].first.piece.label} decks" : ''
    "#{Units.both(fp[:w], fp[:h])}#{deck} (#{make['name']} #{md['name']})"
  end

  def self.export_csv
    r = @last_report
    return UI.messagebox('Generate a stage first.') unless r
    path = UI.savepanel('Export block list', nil, 'StageForge block list.csv')
    return unless path
    path += '.csv' unless path.downcase.end_with?('.csv')
    CSV.open(path, 'w', encoding: 'UTF-8') do |csv|
      csv << ["StageForge v#{r[:version]}", r[:stage]]
      csv << ['Platform size', r[:quote]] if r[:quote]
      csv << []
      csv << ['Block', 'Size', 'Qty', 'Area']
      r[:rows].each { |x| csv << [x[:name], x[:dims], x[:qty], x[:area]] }
      csv << []
      csv << ['Total blocks', r[:total_blocks]]
      csv << ['Stage area covered', r[:covered]]
      csv << ['Boundary area', r[:boundary]]
      csv << ['Uncovered', r[:uncovered], "#{r[:coverage]}% covered"]
      csv << [r[:fascia] == 'none' ? 'Perimeter (drawn outline)' : 'Fascia length', r[:perimeter], "Fascia: #{r[:fascia]}"]
      if r[:steps].to_i > 0
        csv << ['Steps', r[:steps], "rise #{r[:rise]}", r[:inside] ? 'inside the boundary' : 'outside the boundary']
      end
      csv << []
      csv << ['Legs', 'Length', 'Qty', 'Type']
      r[:legs].each { |l| csv << ['Leg', l[:length], l[:qty], l[:kind]] }
      csv << ['Total legs', '', r[:total_legs], "Legs are #{r[:leg_deduction]} shorter than the finished height"]
    end
    UI.messagebox("Saved:\n#{path}")
  end

  # ------------------------------------------------------------------
  # Menu
  # ------------------------------------------------------------------
  unless file_loaded?(__FILE__)
    menu = UI.menu('Extensions').add_submenu('StageForge')
    menu.add_item('Stage Builder...') { show_dialog }
    menu.add_item('Seating Planner...') { SeatingUI.show_dialog }
    menu.add_item('About StageForge') do
      UI.messagebox("StageForge v#{VERSION}\n\nStage planning and event seating for SketchUp.\n" \
                    "Menu: Extensions > StageForge.")
    end
    menu.add_item('Open user catalog folder') do
      dir = Catalog.ensure_user_file
      UI.openURL("file:///#{dir.tr('\\', '/').sub(%r{\A/}, '')}")
    end
    file_loaded(__FILE__)
  end
end
