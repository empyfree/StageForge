# frozen_string_literal: true

# Tiered steps along a marked edge (pure Ruby, plan coordinates in inches).
#
# Distances are measured outward from the stage edge E. With deck depth D, overlap o and
# pitch p = D - o, tier k (k = 1 is the highest step, next to the stage) occupies
#     from (k-1)p - o   to   k p
# so each tier runs UNDER the next higher one by o. Tier tops step down evenly from the
# stage height: top_k = H - k * rise, where rise = H / (steps + 1).
#
# Outside mode: E is the marked edge itself and the steps are added beyond it.
# Inside mode:  E is the marked edge moved inwards by steps * p, so the steps finish on the
#               marked edge; the caller clips the stage region back to E (see :clips).
module StageForge
  module Tiers
    def self.unit(v)
      l = Math.hypot(v[0], v[1])
      l < 1e-12 ? [1.0, 0.0] : [v[0] / l, v[1] / l]
    end

    # Suggested number of steps for a stage height, aiming at target_rise per riser
    # (nearest whole number of risers, halves round towards fewer steps).
    # With a 200 mm target: 600 -> 2, 900 -> 3 (rise 225), 1200 -> 5 (rise 200).
    def self.suggest(height, target_rise)
      risers = [(height / target_rise - 0.5 - 1e-9).ceil, 1].max
      risers - 1
    end

    # True if segment a-b runs along line ln (parallel and within tol inches).
    def self.along?(a, b, ln, tol = 3.0)
      u = unit([ln[1][0] - ln[0][0], ln[1][1] - ln[0][1]])
      v = unit([b[0] - a[0], b[1] - a[1]])
      return false if (u[0] * v[1] - u[1] * v[0]).abs > 0.02
      m = [(a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0]
      Packer.dist_pt_seg(m, ln[0], ln[1]) <= tol
    end

    # Oriented geometry of each marked edge: p1, p2 (outer edge of the stage side) and the
    # outward unit normal n. Pure function so the caller can clip before packing.
    def self.orient(edges, centroid)
      edges.map do |e|
        p1, p2 = e
        t = unit([p2[0] - p1[0], p2[1] - p1[1]])
        n = [-t[1], t[0]]
        mid = [(p1[0] + p2[0]) / 2.0, (p1[1] + p2[1]) / 2.0]
        if n[0] * (mid[0] - centroid[0]) + n[1] * (mid[1] - centroid[1]) < 0
          p1, p2 = p2, p1
          t = unit([p2[0] - p1[0], p2[1] - p1[1]])
          n = [-t[1], t[0]]
        end
        { p1: p1, p2: p2, n: n }
      end
    end

    # Returns { tiers:, fascia:, lines:, clips:, steps:, rise:, notes: }
    def self.build(oriented, deck_d, overlap, steps, height, rect_pieces, want_fascia,
                   inside = false, region = nil)
      out = { tiers: [], fascia: [], lines: [], clips: [], gaps: [], steps: steps, rise: 0.0, notes: [] }
      if steps < 1
        out[:notes] << 'No steps were needed for this height.'
        return out
      end
      rise = height / (steps + 1)
      out[:rise] = rise
      pitch = deck_d - overlap
      oriented.each do |o|
        p1 = o[:p1]
        p2 = o[:p2]
        n = o[:n]
        if inside
          shift = steps * pitch
          p1 = [p1[0] - n[0] * shift, p1[1] - n[1] * shift]
          p2 = [p2[0] - n[0] * shift, p2[1] - n[1] * shift]
          out[:clips] << { p: p1, n: n }
        end
        out[:lines] << [p1, p2]
        tdir = unit([p2[0] - p1[0], p2[1] - p1[1]])
        edge_len = Math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        at = lambda { |base, dist| [base[0] + n[0] * dist, base[1] + n[1] * dist] }
        (1..steps).each do |k|
          s = (k - 1) * pitch - overlap
          en = k * pitch
          poly = [at.call(p1, s), at.call(p2, s), at.call(p2, en), at.call(p1, en)]
          res = Packer.run(poly, [], rect_pieces, max_seconds: 3, angle_count: 1, offset_n: 1, finalists: 1)
          placed = res[:placed]
          # Split any leftover length evenly at both ends of the strip.
          Packer.centre_along(placed, Packer::Region.new(poly, []), poly, tdir)
          q1 = p1
          q2 = p2
          unless placed.empty?
            base = p1[0] * tdir[0] + p1[1] * tdir[1]
            ps = placed.flat_map { |pl| pl.pts.map { |q| q[0] * tdir[0] + q[1] * tdir[1] } }
            out[:gaps] << edge_len - (ps.max - ps.min) if k == 1
            q1 = [p1[0] + tdir[0] * (ps.min - base), p1[1] + tdir[1] * (ps.min - base)]
            q2 = [p1[0] + tdir[0] * (ps.max - base), p1[1] + tdir[1] * (ps.max - base)]
          end
          if inside && region
            kept = placed.select { |pl| Packer.fits?(pl.pts, region) }
            out[:notes] << 'Some step decks fall outside the boundary and were left out.' if kept.size < placed.size
            placed = kept
          end
          top = height - k * rise
          out[:tiers] << { k: k, top: top, poly: poly, placed: placed }
          if placed.empty?
            out[:notes] << 'A step strip was too short for any enabled deck.'
          end
          next unless want_fascia
          e_prev = (k - 1) * pitch
          zb_riser = k < steps ? height - (k + 1) * rise : 0.0
          out[:fascia] << { pts: [at.call(q2, en), at.call(q1, en)], closed: false, zb: zb_riser, zt: top }
          out[:fascia] << { pts: [at.call(q1, en), at.call(q1, e_prev)], closed: false, zb: 0.0, zt: top }
          out[:fascia] << { pts: [at.call(q2, e_prev), at.call(q2, en)], closed: false, zb: 0.0, zt: top }
        end
      end
      out[:notes].uniq!
      out
    end
  end
end
