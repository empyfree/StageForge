# frozen_string_literal: true

# Seating layout engine. Pure Ruby (no SketchUp API). Plan coordinates in inches.
#
# Chairs are described by a centre point (the centre of the chair's footprint box)
# and a unit facing direction. Pitches are measured between those centres:
#   side  = chair-to-chair along a row
#   row   = front-to-front between successive rows
module StageForge
  module Seating
    Chair = Struct.new(:x, :y, :dx, :dy, :row)

    def self.footprint(x, y, dx, dy, len, wid)
      sx = -dy
      sy = dx
      hl = len / 2.0
      hw = wid / 2.0
      [
        [x - dx * hl - sx * hw, y - dy * hl - sy * hw],
        [x + dx * hl - sx * hw, y + dy * hl - sy * hw],
        [x + dx * hl + sx * hw, y + dy * hl + sy * hw],
        [x - dx * hl + sx * hw, y - dy * hl + sy * hw]
      ]
    end

    def self.centroid(pts)
      a = 0.0
      cx = 0.0
      cy = 0.0
      n = pts.size
      n.times do |i|
        p = pts[i]
        q = pts[(i + 1) % n]
        c = p[0] * q[1] - q[0] * p[1]
        a += c
        cx += (p[0] + q[0]) * c
        cy += (p[1] + q[1]) * c
      end
      return [pts.map { |p| p[0] }.sum / n, pts.map { |p| p[1] }.sum / n] if a.abs < 1e-9
      [cx / (3.0 * a), cy / (3.0 * a)]
    end

    def self.min_dist_to_region(pt, outer)
      best = Float::INFINITY
      n = outer.size
      n.times do |i|
        d = Packer.dist_pt_seg(pt, outer[i], outer[(i + 1) % n])
        best = d if d < best
      end
      best
    end

    # True if the convex footprint overlaps the interior of any aisle region.
    def self.blocked?(pts, aisles)
      return false if aisles.nil? || aisles.empty?
      bb = Packer.bbox(pts)
      n = pts.size
      cx = pts.map { |p| p[0] }.sum / n
      cy = pts.map { |p| p[1] }.sum / n
      sg = Packer.sgn(pts)
      aisles.each do |ar|
        next if bb[2] <= ar.minx || bb[0] >= ar.maxx || bb[3] <= ar.miny || bb[1] >= ar.maxy
        edges = ar.near_edges(bb)
        n.times do |i|
          a = pts[i]
          b = pts[(i + 1) % n]
          edges.each { |e| return true if Packer.proper_cross?(a, b, e) }
        end
        probes = pts.dup
        n.times { |i| probes << [(pts[i][0] + pts[(i + 1) % n][0]) / 2.0, (pts[i][1] + pts[(i + 1) % n][1]) / 2.0] }
        probes << [cx, cy]
        probes.each { |p| return true if ar.state(p) == :in }
        ar.near_verts(bb).each { |v| return true if Packer.strictly_inside_convex?(v, pts, sg) }
      end
      false
    end

    # Rows parallel to a straight front line.
    # front: { mid: [x,y], f: [fx,fy] }  (f = unit vector pointing TOWARDS the front)
    # prm: :side :row :len :wid :clearance :margin :stagger :align ('center'|'best')
    def self.straight(region, outer, front, prm)
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
      rowp = prm[:row]
      len = prm[:len]
      wid = prm[:wid]
      m2 = prm[:margin] * 2.0
      # The front row sits on the front edge of the area (its bounding box, measured square to
      # the front), offset by the clear space; every later row follows at the row pitch, so any
      # spare depth is lost at the back. Across the width the rows are centred on the area.
      vc = (vmin + vmax) / 2.0
      u_first = umin + prm[:clearance] + prm[:margin] + len / 2.0
      j0 = 0
      j1 = ((umax - u_first) / rowp).ceil + 1
      trials = prm[:align] == 'best' ? (0...8).map { |k| k * side / 8.0 } : [0.0, side / 2.0]
      best = nil
      trials.each do |shift|
        chairs = []
        (j0..j1).each do |j|
          u = u_first + j * rowp
          base = shift + (prm[:stagger] && j.odd? ? side / 2.0 : 0.0)
          i0 = ((vmin - vc - base) / side).floor - 1
          i1 = ((vmax - vc - base) / side).ceil + 1
          (i0..i1).each do |i|
            v = vc + base + i * side
            x = mid[0] - fx * u + sx * v
            y = mid[1] - fy * u + sy * v
            fp = footprint(x, y, fx, fy, len + m2, wid + m2)
            next unless Packer.fits?(fp, region)
            next if blocked?(fp, prm[:aisles])
            chairs << Chair.new(x, y, fx, fy, j)
          end
        end
        best = chairs if best.nil? || chairs.size > best.size
      end
      best
    end

    # Concentric rows around a focal point; every chair faces the focal point.
    # prm: :focal [x,y], :r0 (radius of front row centre line), :side :row :len :wid
    #      :margin :stagger
    def self.curved(region, outer, prm)
      px, py = prm[:focal]
      side = prm[:side]
      rowp = prm[:row]
      len = prm[:len]
      wid = prm[:wid]
      m2 = prm[:margin] * 2.0
      rmax = outer.map { |p| Math.hypot(p[0] - px, p[1] - py) }.max
      inside = Packer.pip_state([px, py], outer) != :out
      rmin = inside ? 0.0 : min_dist_to_region([px, py], outer)
      cx, cy = centroid(outer)
      phic = Math.hypot(cx - px, cy - py) < 1e-6 ? 0.0 : Math.atan2(cy - py, cx - px)
      chairs = []
      j = 0
      loop do
        r = prm[:r0] + j * rowp
        break if r - len / 2.0 > rmax
        if r + len / 2.0 >= rmin
          dphi = side / r
          kmax = (Math::PI / dphi).floor + 1
          off = prm[:stagger] && j.odd? ? 0.5 : 0.0
          (-kmax..kmax).each do |k|
            a = (k + off) * dphi
            next if a > Math::PI || a <= -Math::PI
            phi = phic + a
            c = Math.cos(phi)
            s = Math.sin(phi)
            x = px + r * c
            y = py + r * s
            fp = footprint(x, y, -c, -s, len + m2, wid + m2)
            next unless Packer.fits?(fp, region)
            next if blocked?(fp, prm[:aisles])
            chairs << Chair.new(x, y, -c, -s, j)
          end
        end
        j += 1
        break if j > 2000
      end
      chairs
    end

    # mode: 'equal' | 'offset' | 'curved'
    def self.run(mode, outer, holes, front, prm)
      region = Packer::Region.new(outer, holes)
      chairs =
        if mode == 'curved'
          curved(region, outer, prm)
        else
          straight(region, outer, front, prm.merge(stagger: mode == 'offset'))
        end
      used = chairs.map(&:row).uniq.sort
      map = {}
      used.each_with_index { |r, i| map[r] = i + 1 }
      chairs.each { |c| c.row = map[c.row] }
      rows = used.each_index.map { |i| { row: i + 1, count: chairs.count { |c| c.row == i + 1 } } }
      notes = []
      notes << 'Side pitch is smaller than the chair width, so neighbouring chairs overlap.' if prm[:side] < prm[:wid] - 0.04
      notes << 'Front-to-front pitch is smaller than the chair depth, so rows overlap.' if prm[:row] < prm[:len] - 0.04
      { chairs: chairs, rows: rows, notes: notes }
    end
  end
end
