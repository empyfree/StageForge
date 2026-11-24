# frozen_string_literal: true

# StageForge packing engine.
#
# Pure Ruby (no SketchUp API) so it can be unit-tested outside SketchUp.
# All coordinates are plan-view [x, y] pairs in inches.
#
# Strategy
#   Phase 1 - "grid fill": for several candidate grid orientations (aligned to the
#             longest boundary edges, plus the 3 other 90 degree starting corners) and
#             grid offsets, greedily fill the boundary with rectangular decks, largest
#             first, using a fast cell occupancy grid. Best layouts are kept.
#   Phase 2 - "gap fill": for each kept layout, repeatedly try every enabled block
#             (triangles, quadrants, semicircles, corners, rectangles...) anchored to
#             boundary vertices and to the vertices of blocks already placed, aligned
#             to those edges. Valid candidates are accepted largest-area first.
#   The layout with the most area covered (then fewest blocks) wins.
module StageForge
  module Packer
    EPS = 1e-3 # inches
    HALF_PI = Math::PI / 2.0
    TWO_PI = Math::PI * 2.0
    ARC_SEGS_PER_QUADRANT = 6

    Piece  = Struct.new(:id, :name, :label, :shape, :local, :arc, :area, :bw, :bh,
                        :rect, :frames, :variants)
    Placed = Struct.new(:piece, :m, :angle, :tx, :ty, :pts, :area, :bb, :sgn)

    # ------------------------------------------------------------------
    # Basic geometry
    # ------------------------------------------------------------------
    def self.cross(o, a, b)
      (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    end

    def self.signed_area(pts)
      s = 0.0
      n = pts.size
      n.times do |i|
        a = pts[i]
        b = pts[(i + 1) % n]
        s += a[0] * b[1] - b[0] * a[1]
      end
      s * 0.5
    end

    def self.polygon_area(pts)
      signed_area(pts).abs
    end

    def self.sgn(pts)
      signed_area(pts) >= 0 ? 1 : -1
    end

    def self.bbox(pts)
      minx = maxx = pts[0][0]
      miny = maxy = pts[0][1]
      pts.each do |p|
        minx = p[0] if p[0] < minx
        maxx = p[0] if p[0] > maxx
        miny = p[1] if p[1] < miny
        maxy = p[1] if p[1] > maxy
      end
      [minx, miny, maxx, maxy]
    end

    def self.bb_overlap?(a, b)
      a[0] < b[2] - EPS && b[0] < a[2] - EPS && a[1] < b[3] - EPS && b[1] < a[3] - EPS
    end

    def self.convex?(pts)
      n = pts.size
      return false if n < 3
      sign = 0
      n.times do |i|
        c = cross(pts[i], pts[(i + 1) % n], pts[(i + 2) % n])
        next if c.abs < 1e-9
        s = c > 0 ? 1 : -1
        return false if sign != 0 && s != sign
        sign = s
      end
      true
    end

    def self.dist_pt_seg(p, a, b)
      dx = b[0] - a[0]
      dy = b[1] - a[1]
      l2 = dx * dx + dy * dy
      t = l2 < 1e-18 ? 0.0 : ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2
      t = 0.0 if t < 0.0
      t = 1.0 if t > 1.0
      Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy))
    end

    # :in, :on or :out relative to a simple polygon.
    def self.pip_state(pt, poly)
      inside = false
      n = poly.size
      j = n - 1
      n.times do |i|
        a = poly[j]
        b = poly[i]
        if pt[0] >= (a[0] < b[0] ? a[0] : b[0]) - EPS && pt[0] <= (a[0] > b[0] ? a[0] : b[0]) + EPS &&
           pt[1] >= (a[1] < b[1] ? a[1] : b[1]) - EPS && pt[1] <= (a[1] > b[1] ? a[1] : b[1]) + EPS
          return :on if dist_pt_seg(pt, a, b) <= EPS
        end
        if (a[1] > pt[1]) != (b[1] > pt[1])
          xint = a[0] + (pt[1] - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
          inside = !inside if pt[0] < xint
        end
        j = i
      end
      inside ? :in : :out
    end

    # Segment a-b crosses edge e=[cx,cy,dx,dy] at a point interior to both.
    def self.proper_cross?(a, b, e)
      cx = e[0]
      cy = e[1]
      dx = e[2]
      dy = e[3]
      abx = b[0] - a[0]
      aby = b[1] - a[1]
      d1 = abx * (cy - a[1]) - aby * (cx - a[0])
      d2 = abx * (dy - a[1]) - aby * (dx - a[0])
      t1 = EPS * Math.hypot(abx, aby)
      return false unless (d1 > t1 && d2 < -t1) || (d1 < -t1 && d2 > t1)
      cdx = dx - cx
      cdy = dy - cy
      d3 = cdx * (a[1] - cy) - cdy * (a[0] - cx)
      d4 = cdx * (b[1] - cy) - cdy * (b[0] - cx)
      t2 = EPS * Math.hypot(cdx, cdy)
      (d3 > t2 && d4 < -t2) || (d3 < -t2 && d4 > t2)
    end

    def self.strictly_inside_convex?(v, pts, sg)
      n = pts.size
      n.times do |i|
        a = pts[i]
        b = pts[(i + 1) % n]
        c = cross(a, b, v) * sg
        return false if c <= EPS * Math.hypot(b[0] - a[0], b[1] - a[1])
      end
      true
    end

    # True if the interiors of two convex polygons overlap by more than EPS.
    def self.overlap?(p, q)
      [p, q].each do |poly|
        n = poly.size
        n.times do |i|
          a = poly[i]
          b = poly[(i + 1) % n]
          ax = -(b[1] - a[1])
          ay = b[0] - a[0]
          len = Math.hypot(ax, ay)
          next if len < 1e-12
          ax /= len
          ay /= len
          min1 = Float::INFINITY
          max1 = -Float::INFINITY
          p.each do |v|
            d = v[0] * ax + v[1] * ay
            min1 = d if d < min1
            max1 = d if d > max1
          end
          min2 = Float::INFINITY
          max2 = -Float::INFINITY
          q.each do |v|
            d = v[0] * ax + v[1] * ay
            min2 = d if d < min2
            max2 = d if d > max2
          end
          return false if max1 <= min2 + EPS || max2 <= min1 + EPS
        end
      end
      true
    end

    # ------------------------------------------------------------------
    # Region (outer boundary + holes) with a bucket grid for fast queries
    # ------------------------------------------------------------------
    class Region
      attr_reader :loops, :minx, :miny, :maxx, :maxy

      def initialize(outer, holes)
        @outer = outer
        @holes = holes
        @loops = [outer] + holes
        xs = outer.map { |p| p[0] }
        ys = outer.map { |p| p[1] }
        @minx, @maxx = xs.minmax
        @miny, @maxy = ys.minmax
        @edges = []
        @verts = []
        @loops.each do |lp|
          n = lp.size
          n.times do |i|
            a = lp[i]
            b = lp[(i + 1) % n]
            @edges << [a[0], a[1], b[0], b[1]]
            @verts << a
          end
        end
        build_grid
      end

      def build_grid
        w = @maxx - @minx
        h = @maxy - @miny
        @g = [[w, h].max / 120.0, 0.5].max
        @nx = (w / @g).floor + 1
        @ny = (h / @g).floor + 1
        @cell_edges = Array.new(@nx * @ny)
        @cell_verts = Array.new(@nx * @ny)
        @cls = Array.new(@nx * @ny)
        @edges.each_with_index do |e, k|
          len = Math.hypot(e[2] - e[0], e[3] - e[1])
          steps = [(len / @g).ceil, 1].max
          steps.times do |s|
            t0 = s.to_f / steps
            t1 = (s + 1).to_f / steps
            x0 = e[0] + (e[2] - e[0]) * t0
            y0 = e[1] + (e[3] - e[1]) * t0
            x1 = e[0] + (e[2] - e[0]) * t1
            y1 = e[1] + (e[3] - e[1]) * t1
            ci0, cj0 = cell_xy([[x0, x1].min - EPS, [y0, y1].min - EPS])
            ci1, cj1 = cell_xy([[x0, x1].max + EPS, [y0, y1].max + EPS])
            (cj0..cj1).each do |cj|
              (ci0..ci1).each do |ci|
                idx = cj * @nx + ci
                list = (@cell_edges[idx] ||= [])
                list << k unless list.last == k
              end
            end
          end
        end
        @verts.each_with_index do |v, k|
          ci, cj = cell_xy(v)
          (@cell_verts[cj * @nx + ci] ||= []) << k
        end
      end

      def cell_xy(p)
        ci = ((p[0] - @minx) / @g).floor
        cj = ((p[1] - @miny) / @g).floor
        ci = 0 if ci < 0
        cj = 0 if cj < 0
        ci = @nx - 1 if ci > @nx - 1
        cj = @ny - 1 if cj > @ny - 1
        [ci, cj]
      end

      def exact_state(pt)
        s = Packer.pip_state(pt, @outer)
        return :out if s == :out
        return :on if s == :on
        @holes.each do |h|
          hs = Packer.pip_state(pt, h)
          return :on if hs == :on
          return :out if hs == :in
        end
        :in
      end

      def state(pt)
        x = pt[0]
        y = pt[1]
        return :out if x < @minx - EPS || x > @maxx + EPS || y < @miny - EPS || y > @maxy + EPS
        ci, cj = cell_xy(pt)
        idx = cj * @nx + ci
        ce = @cell_edges[idx]
        if ce.nil?
          c = @cls[idx]
          if c.nil?
            c = exact_state([@minx + (ci + 0.5) * @g, @miny + (cj + 0.5) * @g])
            @cls[idx] = c
          end
          return c
        end
        exact_state(pt)
      end

      def within_bbox?(bb)
        bb[0] >= @minx - EPS && bb[1] >= @miny - EPS && bb[2] <= @maxx + EPS && bb[3] <= @maxy + EPS
      end

      def near_edges(bb)
        collect(bb, @cell_edges, @edges)
      end

      def near_verts(bb)
        collect(bb, @cell_verts, @verts)
      end

      def collect(bb, cells, source)
        ci0, cj0 = cell_xy([bb[0] - EPS, bb[1] - EPS])
        ci1, cj1 = cell_xy([bb[2] + EPS, bb[3] + EPS])
        seen = {}
        out = []
        (cj0..cj1).each do |cj|
          (ci0..ci1).each do |ci|
            list = cells[cj * @nx + ci]
            next unless list
            list.each do |k|
              next if seen[k]
              seen[k] = true
              out << source[k]
            end
          end
        end
        out
      end
    end

    # Does the convex polygon lie entirely inside the region?
    def self.fits?(pts, region)
      bb = bbox(pts)
      return false unless region.within_bbox?(bb)
      n = pts.size
      pts.each { |p| return false if region.state(p) == :out }
      n.times do |i|
        a = pts[i]
        b = pts[(i + 1) % n]
        return false if region.state([(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5]) == :out
      end
      edges = region.near_edges(bb)
      unless edges.empty?
        n.times do |i|
          a = pts[i]
          b = pts[(i + 1) % n]
          edges.each { |e| return false if proper_cross?(a, b, e) }
        end
      end
      verts = region.near_verts(bb)
      unless verts.empty?
        sg = sgn(pts)
        verts.each { |v| return false if strictly_inside_convex?(v, pts, sg) }
      end
      true
    end

    # ------------------------------------------------------------------
    # Spatial index of placed pieces
    # ------------------------------------------------------------------
    class Index
      def initialize(cell)
        @cell = [cell, 1.0].max
        @h = {}
      end

      def add(pl)
        each_key(pl.bb) { |k| (@h[k] ||= []) << pl }
      end

      def query(bb)
        seen = {}
        out = []
        each_key(bb) do |k|
          list = @h[k]
          next unless list
          list.each do |pl|
            next if seen[pl.object_id]
            seen[pl.object_id] = true
            out << pl
          end
        end
        out
      end

      def each_key(bb)
        x0 = (bb[0] / @cell).floor
        x1 = (bb[2] / @cell).floor
        y0 = (bb[1] / @cell).floor
        y1 = (bb[3] / @cell).floor
        (x0..x1).each { |i| (y0..y1).each { |j| yield [i, j] } }
      end
    end

    def self.hit?(poly, bb, index)
      index.query(bb).any? { |pl| bb_overlap?(bb, pl.bb) && overlap?(poly, pl.pts) }
    end

    # ------------------------------------------------------------------
    # Pieces
    # ------------------------------------------------------------------
    def self.arc_points(cx, cy, r, a0, a1, segs)
      (0..segs).map do |k|
        t = a0 + (a1 - a0) * k.to_f / segs
        [cx + r * Math.cos(t), cy + r * Math.sin(t)]
      end
    end

    # blk: Hash from the catalog (string keys), to_in: multiplier to convert its
    # dimensions to inches.
    def self.build_piece(blk, to_in)
      id = blk['id'].to_s
      f = lambda do |k|
        raise "block '#{id}' is missing '#{k}'" if blk[k].nil?
        v = blk[k].to_f * to_in
        raise "block '#{id}': '#{k}' must be positive" unless v > 0
        v
      end
      shape = blk['shape'].to_s
      case shape
      when 'rect'
        w = f.call('w')
        h = f.call('h')
        local = [[0.0, 0.0], [w, 0.0], [w, h], [0.0, h]]
        arc = [false, false, false, false]
      when 'tri'
        w = f.call('w')
        h = f.call('h')
        local = [[0.0, 0.0], [w, 0.0], [0.0, h]]
        arc = [false, false, false]
      when 'quad'
        r = f.call('r')
        pts = arc_points(0.0, 0.0, r, 0.0, HALF_PI, ARC_SEGS_PER_QUADRANT)
        local = [[0.0, 0.0]] + pts
        arc = Array.new(local.size, false)
        (1..ARC_SEGS_PER_QUADRANT).each { |i| arc[i] = true }
      when 'semi'
        r = f.call('r')
        m = ARC_SEGS_PER_QUADRANT * 2
        pts = arc_points(r, 0.0, r, 0.0, Math::PI, m)[0...m] # drop duplicate of (0,0)
        local = [[0.0, 0.0]] + pts
        arc = Array.new(local.size, true)
        arc[0] = false
      when 'chamfer'
        w = f.call('w')
        h = f.call('h')
        c = f.call('cut')
        raise "block '#{id}': cut too large" if c >= w || c >= h
        local = [[0.0, 0.0], [w, 0.0], [w, h - c], [w - c, h], [0.0, h]]
        arc = Array.new(5, false)
      when 'poly'
        raw = blk['points']
        raise "block '#{id}': 'points' needed" unless raw.is_a?(Array) && raw.size >= 3
        local = raw.map { |p| [p[0].to_f * to_in, p[1].to_f * to_in] }
        raise "block '#{id}': polygon must be convex" unless convex?(local)
        local.reverse! if signed_area(local) < 0
        minx = local.map { |p| p[0] }.min
        miny = local.map { |p| p[1] }.min
        local = local.map { |p| [p[0] - minx, p[1] - miny] }
        arc = Array.new(local.size, false)
      else
        raise "block '#{id}': unknown shape '#{shape}'"
      end
      bb = bbox(local)
      pc = Piece.new(id, (blk['name'] || id).to_s, (blk['_label'] || blk['name'] || id).to_s, shape,
                     local, arc, polygon_area(local), bb[2] - bb[0], bb[3] - bb[1],
                     shape == 'rect', nil, nil)
      pc.frames = build_frames(pc)
      pc.variants = rect_variants(pc) if pc.rect
      pc
    end

    # Distinct ways of pinning one straight edge of the piece (starting at a chosen
    # vertex) to a direction, on either side, mirrored or not.
    def self.build_frames(pc)
      frames = []
      seen = {}
      n = pc.local.size
      [0, 1].each do |m|
        q = pc.local.map { |p| m == 1 ? [-p[0], p[1]] : [p[0], p[1]] }
        n.times do |e|
          next if pc.arc[e]
          [[e, (e + 1) % n], [(e + 1) % n, e]].each do |v, u|
            ang = Math.atan2(q[u][1] - q[v][1], q[u][0] - q[v][0])
            c = Math.cos(-ang)
            s = Math.sin(-ang)
            rel = q.map do |p|
              dx = p[0] - q[v][0]
              dy = p[1] - q[v][1]
              [dx * c - dy * s, dx * s + dy * c]
            end
            sig = rel.map { |p| [(p[0] * 100).round, (p[1] * 100).round] }.sort
            next if seen[sig]
            seen[sig] = true
            frames << { m: m, v: v, ang: ang, rel: rel, qv: q[v] }
          end
        end
      end
      frames
    end

    def self.rect_variants(pc)
      v = [{ piece: pc, w: pc.bw, h: pc.bh, k: 0, sx: 0.0, sy: 0.0, area: pc.area }]
      if (pc.bw - pc.bh).abs > EPS
        v << { piece: pc, w: pc.bh, h: pc.bw, k: 1, sx: pc.bh, sy: 0.0, area: pc.area }
      end
      v
    end

    def self.world_pts(local, m, angle, tx, ty)
      c = Math.cos(angle)
      s = Math.sin(angle)
      local.map do |p|
        x = m == 1 ? -p[0] : p[0]
        y = p[1]
        [tx + x * c - y * s, ty + x * s + y * c]
      end
    end

    def self.make_placed(pc, m, angle, tx, ty)
      pts = world_pts(pc.local, m, angle, tx, ty)
      Placed.new(pc, m, angle, tx, ty, pts, pc.area, bbox(pts), sgn(pts))
    end

    def self.place_frame(fr, anchor, alpha)
      c = Math.cos(alpha)
      s = Math.sin(alpha)
      ax = anchor[0]
      ay = anchor[1]
      fr[:rel].map { |p| [ax + p[0] * c - p[1] * s, ay + p[0] * s + p[1] * c] }
    end

    # ------------------------------------------------------------------
    # Orientation preference: a plain rectangular stage is laid the way a technician would,
    # i.e. the default deck's long edge runs along whichever side it divides evenly into
    # (the longer side if both do). Only used to break ties between equally good layouts.
    # ------------------------------------------------------------------
    def self.preferred_axis(outer, holes, deck)
      return nil unless deck && holes.empty? && outer.size == 4
      long = [deck.bw, deck.bh].max
      return nil if long < 1.0
      e = Array.new(4) { |i| [outer[(i + 1) % 4][0] - outer[i][0], outer[(i + 1) % 4][1] - outer[i][1]] }
      l = e.map { |v| Math.hypot(v[0], v[1]) }
      return nil if l.any? { |x| x < EPS }
      return nil if (e[0][0] * e[1][0] + e[0][1] * e[1][1]).abs / (l[0] * l[1]) > 0.02
      divides = lambda do |x|
        r = x % long
        x >= long - 0.05 && (r < 0.05 || long - r < 0.05)
      end
      a1 = Math.atan2(e[0][1], e[0][0])
      c = []
      c << [l[0], a1] if divides.call(l[0])
      c << [l[1], a1 + HALF_PI] if divides.call(l[1])
      return nil if c.empty?
      { piece: deck, angle: c.max_by { |x| x[0] }[1] }
    end

    # Axis angle (radians, any multiple of pi) of a rectangle's long edge.
    def self.axis_misaligned?(long_angle, pref)
      d = (long_angle - pref[:angle]) % Math::PI
      d = Math::PI - d if d > Math::PI / 2.0
      d > 0.02
    end

    def self.misaligned_count(placed, pref)
      return 0 unless pref
      placed.count do |pl|
        pc = pl.piece
        next false unless pc.id == pref[:piece].id && (pc.bw - pc.bh).abs > 0.01
        axis_misaligned?(pl.angle + (pc.bw >= pc.bh ? 0.0 : HALF_PI), pref)
      end
    end

    # ------------------------------------------------------------------
    # Phase 1: rectangular grid fill
    # ------------------------------------------------------------------
    def self.compute_step(rects, region)
      raw = rects.flat_map { |p| [p.bw, p.bh] }
      dims = raw.map { |d| (d * 1000).round }
      g = dims.reduce { |a, b| a.gcd(b) }
      base = g / 1000.0
      # Make the step an exact fraction of the smallest dimension, so the grid does not
      # drift (rounding to 0.001 in would leave cells hanging past the boundary).
      dmin = raw.min
      step = dmin / [(dmin / base).round, 1].max
      step = [dmin / 2.0, 1.0].max if base < 0.9
      w = region.maxx - region.minx
      h = region.maxy - region.miny
      step *= 2 while (w / step) * (h / step) > 40_000
      step
    end

    def self.candidate_angles(outer, holes, count)
      bins = {}
      ([outer] + holes).each do |lp|
        n = lp.size
        n.times do |i|
          a = lp[i]
          b = lp[(i + 1) % n]
          dx = b[0] - a[0]
          dy = b[1] - a[1]
          len = Math.hypot(dx, dy)
          next if len < EPS
          deg = (Math.atan2(dy, dx) * 180.0 / Math::PI) % 90.0
          deg -= 90.0 if deg > 45.0
          key = (deg * 2).round
          bin = (bins[key] ||= { total: 0.0, best: 0.0, ang: deg })
          bin[:total] += len
          if len > bin[:best]
            bin[:best] = len
            bin[:ang] = deg
          end
        end
      end
      list = bins.values.sort_by { |b| -b[:total] }.first(count).map { |b| b[:ang] }
      list << 0.0 unless list.any? { |d| d.abs < 0.01 }
      list
    end

    def self.frame_ctx(outer, holes, theta)
      c = Math.cos(theta)
      s = Math.sin(theta)
      rot = lambda { |p| [p[0] * c + p[1] * s, -p[0] * s + p[1] * c] }
      { theta: theta, region: Region.new(outer.map(&rot), holes.map { |h| h.map(&rot) }) }
    end

    def self.inside_grid(ctx, ox, oy, step)
      reg = ctx[:region]
      gx0 = reg.minx - ox
      gy0 = reg.miny - oy
      nx = [((reg.maxx - gx0) / step - 1e-9).ceil, 1].max
      ny = [((reg.maxy - gy0) / step - 1e-9).ceil, 1].max
      rows = Array.new(ny) do |j|
        y0 = gy0 + j * step
        Array.new(nx) do |i|
          x0 = gx0 + i * step
          fits?([[x0, y0], [x0 + step, y0], [x0 + step, y0 + step], [x0, y0 + step]], reg)
        end
      end
      { rows: rows, nx: nx, ny: ny, gx0: gx0, gy0: gy0, ox: ox, oy: oy }
    end

    def self.greedy(grid, cell_vars)
      free = grid[:rows].map(&:dup)
      nx = grid[:nx]
      ny = grid[:ny]
      items = []
      area = 0.0
      ny.times do |j|
        nx.times do |i|
          next unless free[j][i]
          cell_vars.each do |cv|
            cw = cv[:cw]
            ch = cv[:ch]
            next if i + cw > nx || j + ch > ny
            ok = true
            dj = 0
            while dj < ch && ok
              row = free[j + dj]
              di = 0
              while di < cw
                unless row[i + di]
                  ok = false
                  break
                end
                di += 1
              end
              dj += 1
            end
            next unless ok
            ch.times { |dj2| cw.times { |di2| free[j + dj2][i + di2] = false } }
            items << [cv, i, j]
            area += cv[:v][:area]
            break
          end
        end
      end
      { items: items, area: area, count: items.size }
    end

    def self.materialize(result, ctx, grid, step)
      theta = ctx[:theta]
      c = Math.cos(theta)
      s = Math.sin(theta)
      result[:items].map do |cv, i, j|
        v = cv[:v]
        px = grid[:gx0] + i * step + v[:sx]
        py = grid[:gy0] + j * step + v[:sy]
        tx = px * c - py * s
        ty = px * s + py * c
        make_placed(v[:piece], 0, theta + v[:k] * HALF_PI, tx, ty)
      end
    end

    def self.offset_candidates(ctx, axis, step, limit)
      reg = ctx[:region]
      counts = Hash.new(0)
      reg.loops.each do |lp|
        lp.each do |p|
          v = axis == :x ? p[0] - reg.minx : p[1] - reg.miny
          o = ((-v) % step)
          o = 0.0 if o > step - 0.01
          counts[(o * 100).round / 100.0] += 1
        end
      end
      counts.sort_by { |_o, n| -n }.map(&:first).reject { |o| o < 0.01 }.first(limit - 1)
    end

    def self.phase1(outer, holes, rects, region, opts, deadline)
      step = compute_step(rects, region)
      pref = opts[:pref]
      angle_count = opts[:angle_count] || 4
      offset_n = opts[:offset_n] || 3
      thetas = []
      candidate_angles(outer, holes, angle_count).each do |deg|
        4.times { |k| thetas << (deg * Math::PI / 180.0 + k * HALF_PI) }
      end
      cvs = rects.flat_map do |pc|
        pc.variants.map do |v|
          { v: v, cw: [(v[:w] / step - 1e-6).ceil, 1].max, ch: [(v[:h] / step - 1e-6).ceil, 1].max }
        end
      end
      sorted = {
        wide: cvs.sort_by { |cv| [-cv[:v][:area].round(2), -(cv[:v][:w] - cv[:v][:h]).round(2)] },
        tall: cvs.sort_by { |cv| [-cv[:v][:area].round(2), (cv[:v][:w] - cv[:v][:h]).round(2)] }
      }
      results = []
      run_grid = lambda do |ctx, ox, oy|
        grid = inside_grid(ctx, ox, oy, step)
        %i[wide tall].each do |pr|
          r = greedy(grid, sorted[pr])
          r[:ctx] = ctx
          r[:grid] = grid
          r[:mis] = pref ? r[:items].count do |cv, _i, _j|
            pc = cv[:v][:piece]
            next false unless pc.id == pref[:piece].id && (pc.bw - pc.bh).abs > 0.01
            axis_misaligned?(ctx[:theta] + (cv[:v][:w] >= cv[:v][:h] ? 0.0 : HALF_PI), pref)
          end : 0
          results << r
        end
      end
      thetas.each do |theta|
        break if Time.now > deadline && !results.empty?
        run_grid.call(frame_ctx(outer, holes, theta), 0.0, 0.0)
      end
      if offset_n > 1
        top = []
        results.sort_by { |r| [-r[:area].round, r[:count], r[:mis] || 0] }.each do |r|
          top << r unless top.any? { |t| t[:ctx].equal?(r[:ctx]) }
          break if top.size >= 2
        end
        top.each do |r|
          xs = [0.0] + offset_candidates(r[:ctx], :x, step, offset_n)
          ys = [0.0] + offset_candidates(r[:ctx], :y, step, offset_n)
          xs.each do |ox|
            ys.each do |oy|
              next if ox == 0.0 && oy == 0.0
              break if Time.now > deadline
              run_grid.call(r[:ctx], ox, oy)
            end
          end
        end
      end
      finalists = []
      results.sort_by { |r| [-r[:area].round, r[:count], r[:mis] || 0] }.each do |r|
        key = r[:ctx][:theta].round(3)
        next if finalists.any? { |f| f[:ctx][:theta].round(3) == key }
        finalists << r
        break if finalists.size >= (opts[:finalists] || 3)
      end
      finalists.map { |r| materialize(r, r[:ctx], r[:grid], step) }
    end

    # ------------------------------------------------------------------
    # Phase 2: gap filling with every shape, anchored to existing geometry
    # ------------------------------------------------------------------
    def self.covered?(pt, index)
      bb = [pt[0], pt[1], pt[0], pt[1]]
      index.query(bb).any? { |pl| strictly_inside_convex?(pt, pl.pts, pl.sgn) }
    end

    def self.free_samples(region, index, spacing)
      out = []
      y = region.miny + spacing * 0.5
      while y < region.maxy
        x = region.minx + spacing * 0.5
        while x < region.maxx
          pt = [x, y]
          out << pt if region.state(pt) == :in && !covered?(pt, index)
          x += spacing
        end
        y += spacing
      end
      out
    end

    def self.open_anchors(region, placed, samples, max_diag)
      cell = max_diag
      r2 = (max_diag * 1.01)**2
      sh = {}
      samples.each { |s| (sh[[(s[0] / cell).floor, (s[1] / cell).floor]] ||= []) << s }
      anchors = {}
      add = lambda do |pt, ang|
        ang -= TWO_PI if ang > Math::PI
        ang += TWO_PI if ang <= -Math::PI
        key = [(pt[0] * 100).round, (pt[1] * 100).round]
        a = (anchors[key] ||= { pt: pt, dirs: {} })
        a[:dirs][(ang * 1e4).round] = ang
      end
      both = lambda do |pt, q|
        ang = Math.atan2(q[1] - pt[1], q[0] - pt[0])
        add.call(pt, ang)
        add.call(pt, ang + Math::PI)
      end
      region.loops.each do |lp|
        n = lp.size
        n.times do |i|
          both.call(lp[i], lp[(i + 1) % n])
          both.call(lp[i], lp[i - 1])
        end
      end
      placed.each do |pl|
        n = pl.pts.size
        arc = pl.piece.arc
        n.times do |i|
          p = pl.pts[i]
          both.call(p, pl.pts[(i + 1) % n]) unless arc[i]
          both.call(p, pl.pts[i - 1]) unless arc[i - 1]
        end
      end
      anchors.values.select do |a|
        ci = (a[:pt][0] / cell).floor
        cj = (a[:pt][1] / cell).floor
        found = false
        (ci - 1..ci + 1).each do |i|
          (cj - 1..cj + 1).each do |j|
            list = sh[[i, j]]
            next unless list
            if list.any? { |s| (s[0] - a[:pt][0])**2 + (s[1] - a[:pt][1])**2 <= r2 }
              found = true
              break
            end
          end
          break if found
        end
        found
      end
    end

    def self.fill_gaps(region, placed, pieces, deadline)
      max_diag = pieces.map { |p| Math.hypot(p.bw, p.bh) }.max
      min_ext = pieces.map { |p| [p.bw, p.bh].min }.min
      w = region.maxx - region.minx
      h = region.maxy - region.miny
      spacing = [min_ext / 2.0, Math.sqrt(w * h / 15_000.0), 0.5].max
      index = Index.new(max_diag)
      placed.each { |pl| index.add(pl) }
      40.times do
        break if Time.now > deadline
        samples = free_samples(region, index, spacing)
        break if samples.empty?
        anchors = open_anchors(region, placed, samples, max_diag)
        break if anchors.empty?
        cands = []
        seen = {}
        anchors.each do |a|
          break if Time.now > deadline
          a[:dirs].each_value do |alpha|
            pieces.each do |pc|
              pc.frames.each do |fr|
                poly = place_frame(fr, a[:pt], alpha)
                sig = [pc.id, poly.map { |p| [(p[0] * 10).round, (p[1] * 10).round] }.sort]
                next if seen[sig]
                seen[sig] = true
                next unless fits?(poly, region)
                bb = bbox(poly)
                next if hit?(poly, bb, index)
                cands << [pc, fr, a[:pt], alpha, poly, bb]
              end
            end
          end
        end
        break if cands.empty?
        cands.sort_by! { |c| [-(c[0].area * 10).round, (c[5][1] * 10).round, (c[5][0] * 10).round] }
        added = []
        cands.each do |pc, fr, pt, alpha, poly, bb|
          next if added.any? { |pl| bb_overlap?(bb, pl.bb) && overlap?(poly, pl.pts) }
          phi = alpha - fr[:ang]
          c = Math.cos(phi)
          s = Math.sin(phi)
          qv = fr[:qv]
          tx = pt[0] - (qv[0] * c - qv[1] * s)
          ty = pt[1] - (qv[0] * s + qv[1] * c)
          pl = Placed.new(pc, fr[:m], phi, tx, ty, poly, pc.area, bb, sgn(poly))
          placed << pl
          index.add(pl)
          added << pl
        end
        break if added.empty?
      end
      placed
    end

    # Sutherland-Hodgman clip of a polygon against the half-plane (x - p0) . n <= 0.
    def self.clip_half(poly, p0, n)
      out = []
      m = poly.size
      d = lambda { |p| (p[0] - p0[0]) * n[0] + (p[1] - p0[1]) * n[1] }
      m.times do |i|
        a = poly[i]
        b = poly[(i + 1) % m]
        da = d.call(a)
        db = d.call(b)
        out << a if da <= 0
        if (da < 0 && db > 0) || (da > 0 && db < 0)
          t = da / (da - db)
          out << [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]
        end
      end
      out
    end

    # Convex hull (monotone chain), counter-clockwise, no repeated end point.
    def self.hull(points)
      pts = points.map { |p| [p[0].to_f, p[1].to_f] }.uniq.sort
      return pts if pts.size < 3
      lower = []
      pts.each do |p|
        lower.pop while lower.size >= 2 && cross(lower[-2], lower[-1], p) <= 0
        lower << p
      end
      upper = []
      pts.reverse_each do |p|
        upper.pop while upper.size >= 2 && cross(upper[-2], upper[-1], p) <= 0
        upper << p
      end
      lower[0...-1] + upper[0...-1]
    end

    # Smallest-area oriented rectangle around the points: { w:, h:, theta: } with w >= h.
    def self.min_rect(points)
      h = hull(points)
      return { w: 0.0, h: 0.0, theta: 0.0 } if h.size < 2
      best = nil
      h.each_index do |i|
        a = h[i]
        b = h[(i + 1) % h.size]
        th = Math.atan2(b[1] - a[1], b[0] - a[0])
        c = Math.cos(th)
        s = Math.sin(th)
        us = h.map { |p| p[0] * c + p[1] * s }
        vs = h.map { |p| -p[0] * s + p[1] * c }
        w = us.max - us.min
        d = vs.max - vs.min
        best = { w: w, h: d, theta: th } if best.nil? || w * d < best[:w] * best[:h]
      end
      best[:w], best[:h] = best[:h], best[:w] if best[:h] > best[:w]
      best
    end

    # Greatest common divisor of the deck dimensions (inches, to 0.001).
    def self.deck_base(rects)
      dims = rects.flat_map { |p| [p.bw, p.bh] }.map { |d| (d * 1000).round }
      dims.reduce { |a, b| a.gcd(b) } / 1000.0
    end

    # Most common orientation (mod 90 degrees, radians) of the placed blocks.
    def self.dominant_angle(placed)
      counts = Hash.new(0)
      placed.each do |pl|
        deg = (pl.angle * 180.0 / Math::PI) % 90.0
        counts[(deg * 2).round / 2.0 % 90.0] += 1
      end
      counts.empty? ? 0.0 : counts.max_by { |_d, n| n }[0] * Math::PI / 180.0
    end

    # Rigidly shifts every placed block along unit direction u so the free space is split
    # equally at both ends of the region. Skipped if any block would then leave the region.
    # Returns the shift applied (0.0 if none).
    def self.centre_along(placed, region, outline, u)
      return 0.0 if placed.empty?
      proj = lambda { |p| p[0] * u[0] + p[1] * u[1] }
      lo = placed.flat_map { |pl| pl.pts.map(&proj) }.min
      hi = placed.flat_map { |pl| pl.pts.map(&proj) }.max
      rs = outline.map(&proj)
      s = ((rs.min - lo) + (rs.max - hi)) / 2.0
      return 0.0 if s.abs < 0.01
      moved = placed.map { |pl| pl.pts.map { |p| [p[0] + u[0] * s, p[1] + u[1] * s] } }
      return 0.0 unless moved.all? { |pts| fits?(pts, region) }
      placed.each_with_index do |pl, i|
        pl.pts = moved[i]
        pl.tx += u[0] * s
        pl.ty += u[1] * s
        pl.bb = bbox(moved[i])
      end
      s
    end

    # Length of block edges lying along any of the given lines (used to prefer layouts
    # whose decks sit flush against marked edges).
    def self.contact_length(placed, lines)
      total = 0.0
      lines.each do |c, d|
        len = Math.hypot(d[0] - c[0], d[1] - c[1])
        next if len < EPS
        ux = (d[0] - c[0]) / len
        uy = (d[1] - c[1]) / len
        placed.each do |pl|
          n = pl.pts.size
          n.times do |i|
            next if pl.piece.arc[i]
            a = pl.pts[i]
            b = pl.pts[(i + 1) % n]
            pa = (a[0] - c[0]) * uy - (a[1] - c[1]) * ux
            pb = (b[0] - c[0]) * uy - (b[1] - c[1]) * ux
            next if pa.abs > 1.0 || pb.abs > 1.0
            ta = (a[0] - c[0]) * ux + (a[1] - c[1]) * uy
            tb = (b[0] - c[0]) * ux + (b[1] - c[1]) * uy
            lo = [[ta, tb].min, 0.0].max
            hi = [[ta, tb].max, len].min
            total += hi - lo if hi > lo
          end
        end
      end
      total
    end

    # ------------------------------------------------------------------
    # Public entry point
    # ------------------------------------------------------------------
    # outer: CCW array of [x,y]; holes: array of loops; pieces: array of Piece.
    # opts: :max_seconds, :angle_count, :offset_n, :finalists
    def self.run(outer, holes, pieces, opts = {})
      started = Time.now
      budget = (opts[:max_seconds] || 15).to_f
      region = Region.new(outer, holes)
      boundary_area = polygon_area(outer) - holes.map { |h| polygon_area(h) }.sum
      out = { placed: [], boundary_area: boundary_area, covered_area: 0.0 }
      return out if pieces.empty?
      deadline1 = started + budget * 0.55
      deadline2 = started + budget
      lines = opts[:contact_edges] || []
      opts = opts.merge(pref: preferred_axis(outer, holes, opts[:prefer_deck])) if opts[:prefer_deck]
      rects = pieces.select(&:rect)
      starts = rects.empty? ? [] : phase1(outer, holes, rects, region, opts, deadline1)
      starts = [[]] if starts.empty?
      best = nil
      best_score = nil
      starts.each_with_index do |layout, idx|
        break if idx > 0 && Time.now > deadline2
        placed = fill_gaps(region, layout.dup, pieces, deadline2)
        bonus = lines.empty? ? 0.0 : contact_length(placed, lines) * 10.0
        score = [-(placed.map(&:area).sum + bonus).round, placed.size, misaligned_count(placed, opts[:pref])]
        if best.nil? || (score <=> best_score) < 0
          best = placed
          best_score = score
        end
      end
      out[:placed] = best
      out[:covered_area] = best.map(&:area).sum
      out[:seconds] = Time.now - started
      out
    end
  end
end
