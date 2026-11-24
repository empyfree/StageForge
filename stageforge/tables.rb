# frozen_string_literal: true

# Table plan layout engine. Pure Ruby (no SketchUp API). Plan coordinates in inches.
#
# A table is a round table with seats around it. Two arrangements:
#   dining    - chairs evenly round the table, every chair facing the centre
#   horseshoe - chairs spread over the half of the table furthest from the front, every chair
#               facing the front (parallel, like a conference / cabaret setting)
# Three ways of laying tables into an area:
#   inline    - rows square to the front, tables lined up row to row
#   staggered - alternate rows shifted half a table across and closed up so the tables interlock
#   bestfit   - ignores rows: packs in as many tables as will fit
module StageForge
  module Tables
    SIZES = [60.0, 66.0, 72.0].freeze # table diameters (inches): 5 ft, 5 ft 6 in, 6 ft
    # Suggested centre-to-centre spacing (mm) and seats, by diameter.
    SPACING_MM = { 60.0 => 3000.0, 66.0 => 3250.0, 72.0 => 3500.0 }.freeze
    SEATS = {
      'dining' => { 60.0 => 6, 66.0 => 8, 72.0 => 10 },
      'horseshoe' => { 60.0 => 5, 66.0 => 6, 72.0 => 8 }
    }.freeze
    CHAIR_GAP = 2.0 # inches between the table edge and a pushed-in chair
    HORSESHOE_SPAN = 200.0 * Math::PI / 180.0 # cabaret chairs cover 200 degrees of the table, centred on the back
    CABARET_ROW_FACTOR = 0.75 # cabaret tables sit this much closer front to back
    STAGGER_ROW = Math.sqrt(3.0) / 2.0 # staggered rows close up by this much (equilateral packing)

    Table = Struct.new(:x, :y, :row)
    Seat = Struct.new(:x, :y, :dx, :dy, :table)

    # Suggested values for a table size and arrangement: { spacing:, row_spacing:, seats: } (inches).
    def self.suggest(dia, arrangement)
      key = SIZES.min_by { |s| (s - dia).abs }
      sp = (SPACING_MM[key] || (dia * 25.4 * 1.9)) / 25.4
      { spacing: sp, row_spacing: (arrangement == 'horseshoe' ? sp * CABARET_ROW_FACTOR : sp), seats: (SEATS[arrangement] || SEATS['dining'])[key] || (dia / 10).round }
    end

    def self.unit(v)
      l = Math.hypot(v[0], v[1])
      l < 1e-12 ? [0.0, 1.0] : [v[0] / l, v[1] / l]
    end

    # Seat centres and facings relative to a table centre. front = unit vector towards the front.
    def self.seat_slots(arrangement, dia, seats, chair_len, front)
      r = dia / 2.0 + CHAIR_GAP + chair_len / 2.0
      if arrangement == 'horseshoe'
        base = Math.atan2(-front[1], -front[0]) # straight out of the back
        Array.new(seats) do |i|
          a = base + ((i + 0.5) / seats - 0.5) * HORSESHOE_SPAN
          [r * Math.cos(a), r * Math.sin(a), front[0], front[1]]
        end
      else
        base = Math.atan2(front[1], front[0])
        Array.new(seats) do |i|
          a = base + (i + 0.5) * 2.0 * Math::PI / seats
          [r * Math.cos(a), r * Math.sin(a), -Math.cos(a), -Math.sin(a)]
        end
      end
    end

    # Outline (convex hull) of one table with its chairs, relative to the table centre.
    def self.footprint(arrangement, dia, slots, chair_len, chair_wid, margin)
      pts = Array.new(32) do |i|
        a = i * 2.0 * Math::PI / 32
        [(dia / 2.0 + margin) * Math.cos(a), (dia / 2.0 + margin) * Math.sin(a)]
      end
      slots.each do |sx, sy, dx, dy|
        pts.concat(Seating.footprint(sx, sy, dx, dy, chair_len + 2 * margin, chair_wid + 2 * margin))
      end
      Packer.hull(pts)
    end

    def self.crowding_note(arrangement, dia, seats, chair_len, chair_wid, front)
      slots = seat_slots(arrangement, dia, seats, chair_len, front)
      return nil if slots.size < 2
      pairs = slots.each_cons(2).to_a
      pairs << [slots.last, slots.first] if arrangement != 'horseshoe'
      closest = pairs.map { |a, b| Math.hypot(a[0] - b[0], a[1] - b[1]) }.min
      return nil if closest >= chair_wid - 0.04
      "#{seats} chairs are too many for this table: neighbouring chairs are #{format('%.0f', closest * 25.4)} mm apart " \
        "and the chairs are #{format('%.0f', chair_wid * 25.4)} mm wide, so they overlap."
    end

    # region: Packer::Region of the area; outer: its outline; front: { mid:, f: } (may be nil for
    # best fit); prm: :arrangement :layout :dia :seats :side :row :clearance :margin
    # :chair_len :chair_wid :align :aisles :max_seconds
    def self.run(region, outer, front, prm)
      arr = prm[:arrangement] == 'horseshoe' ? 'horseshoe' : 'dining'
      f = front ? front[:f] : [0.0, 1.0]
      slots = seat_slots(arr, prm[:dia], prm[:seats], prm[:chair_len], f)
      hull = footprint(arr, prm[:dia], slots, prm[:chair_len], prm[:chair_wid], prm[:margin])
      layout = prm[:layout]
      tables =
        case layout
        when 'bestfit'
          # Best fit is never worse than the neat layouts: try them too and keep the fullest.
          fr = front || { mid: [0.0, 0.0], f: f }
          [best_fit(region, outer, hull, prm), straight(region, outer, fr, hull, prm, false),
           straight(region, outer, fr, hull, prm, true)].max_by(&:size)
        else straight(region, outer, front || { mid: [0.0, 0.0], f: f }, hull, prm, layout == 'staggered')
        end
      seats = []
      tables.each_with_index do |t, ti|
        slots.each { |sx, sy, dx, dy| seats << Seat.new(t.x + sx, t.y + sy, dx, dy, ti) }
      end
      used = tables.map(&:row).compact.uniq.sort
      map = {}
      used.each_with_index { |r, i| map[r] = i + 1 }
      tables.each { |t| t.row = map[t.row] if t.row }
      rows = used.each_index.map do |i|
        n = tables.count { |t| t.row == i + 1 }
        { row: i + 1, count: n * prm[:seats], tables: n }
      end
      notes = []
      note = crowding_note(arr, prm[:dia], prm[:seats], prm[:chair_len], prm[:chair_wid], f)
      notes << note if note
      reach = hull.map { |p| Math.hypot(p[0], p[1]) }.max
      mind = Float::INFINITY
      tables.each_with_index { |a, i| tables.each_with_index { |b, j| next if j <= i; d = Math.hypot(a.x - b.x, a.y - b.y); mind = d if d < mind } }
      if mind < prm[:dia] - 0.5
        notes << 'The table spacing is smaller than the table diameter, so tables overlap.'
      elsif arr == 'dining' && layout != 'bestfit' && prm[:side] < 2 * reach - 0.5
        notes << 'The spacing is tighter than the chairs need: chairs of neighbouring tables overlap or touch.'
      end
      { tables: tables, seats: seats, rows: rows, notes: notes, hull: hull }
    end

    def self.ok?(hull, cx, cy, region, aisles)
      pts = hull.map { |p| [p[0] + cx, p[1] + cy] }
      return false unless Packer.fits?(pts, region)
      !Seating.blocked?(pts, aisles)
    end

    # Rows square to the front, like the chair rows: the front row sits on the front edge of the
    # area (spare depth is lost at the back) and each row is centred across the width.
    def self.straight(region, outer, front, hull, prm, stagger)
      mid = front[:mid]
      fx, fy = front[:f]
      sx = -fy
      sy = fx
      umin = Float::INFINITY
      umax = -Float::INFINITY
      vmin = Float::INFINITY
      vmax = -Float::INFINITY
      outer.each do |p|
        u = -((p[0] - mid[0]) * fx + (p[1] - mid[1]) * fy)
        v = (p[0] - mid[0]) * sx + (p[1] - mid[1]) * sy
        umin = u if u < umin
        umax = u if u > umax
        vmin = v if v < vmin
        vmax = v if v > vmax
      end
      side = prm[:side]
      # Staggered: the row spacing is the centre-to-centre distance to the neighbours in the next row.
      rowp = stagger ? Math.sqrt([prm[:row]**2 - (side / 2.0)**2, (prm[:dia] * 0.5)**2].max) : prm[:row]
      reach_front = hull.map { |p| p[0] * fx + p[1] * fy }.max
      vc = (vmin + vmax) / 2.0
      u_first = umin + prm[:clearance] + reach_front
      j1 = ((umax - u_first) / rowp).ceil + 1
      trials = prm[:align] == 'best' ? (0...8).map { |k| k * side / 8.0 } : [0.0, side / 2.0]
      best = nil
      trials.each do |shift|
        found = []
        (0..j1).each do |j|
          u = u_first + j * rowp
          base = shift + (stagger && j.odd? ? side / 2.0 : 0.0)
          i0 = ((vmin - vc - base) / side).floor - 1
          i1 = ((vmax - vc - base) / side).ceil + 1
          (i0..i1).each do |i|
            v = vc + base + i * side
            x = mid[0] - fx * u + sx * v
            y = mid[1] - fy * u + sy * v
            next unless ok?(hull, x, y, region, prm[:aisles])
            found << Table.new(x, y, j)
          end
        end
        best = found if best.nil? || found.size > best.size
      end
      best
    end

    # No rows: try hexagonal grids at several angles and offsets, keep the one that fits most
    # tables, then squeeze in any extra tables wherever they still fit.
    def self.best_fit(region, outer, hull, prm)
      side = prm[:side]
      deadline = Time.now + (prm[:max_seconds] || 6.0)
      bb = [outer.map { |p| p[0] }.min, outer.map { |p| p[1] }.min, outer.map { |p| p[0] }.max, outer.map { |p| p[1] }.max]
      cx = (bb[0] + bb[2]) / 2.0
      cy = (bb[1] + bb[3]) / 2.0
      reach = Math.hypot(bb[2] - bb[0], bb[3] - bb[1]) / 2.0 + side
      n = (reach / (side * STAGGER_ROW)).ceil + 1
      angles = Packer.candidate_angles(outer, [], 3).map { |d| d * Math::PI / 180.0 }
      (0...12).each { |k| angles << k * Math::PI / 12.0 }
      angles.uniq! { |a| (a * 1000).round }
      fracs = [0.0, 0.25, 0.5, 0.75]
      best = []
      angles.each do |th|
        break if Time.now > deadline && !best.empty?
        c = Math.cos(th)
        s = Math.sin(th)
        fracs.each do |ox|
          fracs.each do |oy|
            found = []
            (-n..n).each do |j|
              (-n..n).each do |i|
                a = (i + ox + 0.5 * (j + oy)) * side
                b = (j + oy) * side * STAGGER_ROW
                x = cx + a * c - b * s
                y = cy + a * s + b * c
                next if x < bb[0] - side || x > bb[2] + side || y < bb[1] - side || y > bb[3] + side
                found << Table.new(x, y, nil) if ok?(hull, x, y, region, prm[:aisles])
              end
            end
            best = found if found.size > best.size
          end
        end
      end
      # Fill remaining gaps: any spot that fits and keeps the minimum distance to every table.
      step = side / 6.0
      min2 = (side - 0.01)**2
      y = bb[1]
      while y <= bb[3] && Time.now < deadline + 2.0
        x = bb[0]
        while x <= bb[2]
          if best.none? { |t| (t.x - x)**2 + (t.y - y)**2 < min2 } && ok?(hull, x, y, region, prm[:aisles])
            best << Table.new(x, y, nil)
          end
          x += step
        end
        y += step
      end
      best.sort_by { |t| [(t.y / side).round, t.x] }
    end
  end
end
