# frozen_string_literal: true

# Finds the outside edge of a set of placed blocks (pure Ruby).
# Block edges shared by two blocks cancel out; what is left is the true outline of the
# decking, including around any gaps. Collinear points are merged so that long straight
# runs stay as single segments.
module StageForge
  module Perimeter
    VTOL = 0.02 # inches: vertices closer than this are the same vertex

    class Canon
      def initialize
        @cells = {}
        @pts = []
      end

      def size
        @pts.size
      end

      def pt(k)
        @pts[k]
      end

      def id(p)
        cx = (p[0] / 0.5).floor
        cy = (p[1] / 0.5).floor
        (cx - 1..cx + 1).each do |i|
          (cy - 1..cy + 1).each do |j|
            list = @cells[[i, j]]
            next unless list
            list.each do |k|
              q = @pts[k]
              return k if (q[0] - p[0]).abs <= VTOL && (q[1] - p[1]).abs <= VTOL
            end
          end
        end
        @pts << [p[0], p[1]]
        k = @pts.size - 1
        (@cells[[cx, cy]] ||= []) << k
        k
      end
    end

    def self.simplify(pts, closed)
      pts = pts.dup
      loop do
        n = pts.size
        break if n < 3
        removed = false
        range = closed ? (0...n) : (1...(n - 1))
        range.each do |i|
          a = pts[i - 1]
          b = pts[i]
          c = pts[(i + 1) % n]
          abx = b[0] - a[0]
          aby = b[1] - a[1]
          bcx = c[0] - b[0]
          bcy = c[1] - b[1]
          la = Math.hypot(abx, aby)
          lb = Math.hypot(bcx, bcy)
          next if la < 1e-9 || lb < 1e-9
          cr = (abx * bcy - aby * bcx) / (la * lb)
          dt = (abx * bcx + aby * bcy) / (la * lb)
          if cr.abs < 1e-3 && dt > 0
            pts.delete_at(i)
            removed = true
            break
          end
        end
        break unless removed
      end
      pts
    end

    # placed: array of Packer::Placed; skip: optional lambda(a, b) -> true to drop an edge.
    # Returns [{ pts: [[x,y],...], closed: true/false }, ...]. Walking direction keeps the
    # decking on the LEFT, so the outside is always on the right.
    def self.paths(placed, skip = nil)
      canon = Canon.new
      polys = placed.map do |pl|
        pts = pl.sgn < 0 ? pl.pts.reverse : pl.pts
        pts.map { |p| canon.id(p) }
      end
      grid = {}
      canon.size.times do |k|
        p = canon.pt(k)
        (grid[[(p[0] / 10.0).floor, (p[1] / 10.0).floor]] ||= []) << k
      end
      edges = {}
      polys.each do |ids|
        n = ids.size
        n.times do |i|
          a = ids[i]
          b = ids[(i + 1) % n]
          next if a == b
          pa = canon.pt(a)
          pb = canon.pt(b)
          dx = pb[0] - pa[0]
          dy = pb[1] - pa[1]
          l2 = dx * dx + dy * dy
          splits = []
          ((([pa[0], pb[0]].min - 0.1) / 10.0).floor..(([pa[0], pb[0]].max + 0.1) / 10.0).floor).each do |gi|
            ((([pa[1], pb[1]].min - 0.1) / 10.0).floor..(([pa[1], pb[1]].max + 0.1) / 10.0).floor).each do |gj|
              (grid[[gi, gj]] || []).each do |k|
                next if k == a || k == b
                p = canon.pt(k)
                t = ((p[0] - pa[0]) * dx + (p[1] - pa[1]) * dy) / l2
                next unless t > 1e-6 && t < 1 - 1e-6
                next unless Math.hypot(p[0] - (pa[0] + t * dx), p[1] - (pa[1] + t * dy)) <= 0.05
                splits << [t, k]
              end
            end
          end
          chain = [a] + splits.sort.map(&:last).uniq + [b]
          chain.each_cons(2) do |u, v|
            next if u == v
            if edges.delete([v, u])
              next
            end
            edges[[u, v]] = true
          end
        end
      end
      if skip
        edges.keys.each { |u, v| edges.delete([u, v]) if skip.call(canon.pt(u), canon.pt(v)) }
      end
      outgoing = Hash.new { |h, k| h[k] = [] }
      incoming = Hash.new(0)
      edges.each_key do |u, v|
        outgoing[u] << v
        incoming[v] += 1
      end
      used = {}
      walk = lambda do |start|
        ids = [start]
        cur = start
        loop do
          nxt = outgoing[cur].find { |v| !used[[cur, v]] }
          break unless nxt
          used[[cur, nxt]] = true
          ids << nxt
          cur = nxt
          break if cur == start
        end
        ids
      end
      result = []
      emit = lambda do |ids|
        closed = ids.size > 2 && ids.first == ids.last
        ids = ids[0...-1] if closed
        pts = simplify(ids.map { |k| canon.pt(k) }, closed)
        len = 0.0
        pts.each_cons(2) { |p, q| len += Math.hypot(q[0] - p[0], q[1] - p[1]) }
        result << { pts: pts, closed: closed } if pts.size >= 2 && len > 1.0
      end
      outgoing.keys.select { |u| incoming[u].zero? }.each do |s|
        emit.call(walk.call(s)) while outgoing[s].any? { |v| !used[[s, v]] }
      end
      outgoing.keys.each do |s|
        emit.call(walk.call(s)) while outgoing[s].any? { |v| !used[[s, v]] }
      end
      result
    end
  end
end
