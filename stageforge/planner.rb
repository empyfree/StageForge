# frozen_string_literal: true

# Stage planning without any SketchUp calls: step count, inside/outside steps, packing,
# centring and fascia paths. Everything is in inches.
module StageForge
  module Planner
    # o: :height, :fascia ('none'|'hard'|'soft'), :effort (Hash), :tier_edges ([[p1,p2],..]),
    #    :inside (bool), :overlap (in, nil = half a deck), :rise_target (in),
    #    :steps (Integer or nil = suggested), :default_deck (Piece or nil),
    #    :system ('metric'|'imperial': how notes quote lengths)
    def self.plan(outer, holes, pieces, o)
      height = o[:height]
      sys = o[:system] || 'metric'
      effort = (o[:effort] || {}).dup
      rects = pieces.select(&:rect)
      out = { tiers: nil, steps: 0, suggested: nil, rise: nil, notes: [], stage_outer: outer,
              pitch: nil, overlap: nil, deck_d: nil }
      stage_outer = outer
      tiers = nil
      oriented = []

      edges = o[:tier_edges] || []
      unless edges.empty?
        deck = o[:default_deck] || rects.max_by(&:area)
        raise 'Tiered steps need at least one ticked rectangular deck (ideally a default deck).' unless deck
        deck_d = [deck.bw, deck.bh].min
        overlap = o[:overlap].nil? ? deck_d / 2.0 : o[:overlap]
        unless overlap >= 0 && overlap < deck_d - 0.1
          raise "Step overlap must be between zero and the deck width (#{Units.len(deck_d, sys)})."
        end
        rise_target = o[:rise_target]
        raise 'Step rise must be greater than zero.' unless rise_target && rise_target > 0
        suggested = Tiers.suggest(height, rise_target)
        steps = o[:steps].nil? ? suggested : o[:steps].to_i
        raise 'Number of steps must be between 0 and 12.' unless steps >= 0 && steps <= 12
        pitch = deck_d - overlap
        out.merge!(suggested: suggested, deck_d: deck_d, overlap: overlap, pitch: pitch)

        oriented = Tiers.orient(edges, Seating.centroid(outer))
        inside = o[:inside] ? true : false
        if inside && steps > 0
          shift = steps * pitch
          oriented.each do |ori|
            p0 = [ori[:p1][0] - ori[:n][0] * shift, ori[:p1][1] - ori[:n][1] * shift]
            stage_outer = Packer.clip_half(stage_outer, p0, ori[:n])
            stage_outer = stage_outer.each_with_index.select do |p, i|
              q = stage_outer[i - 1]
              Math.hypot(p[0] - q[0], p[1] - q[1]) > Packer::EPS
            end.map(&:first)
          end
          if stage_outer.size < 3 || Packer.polygon_area(stage_outer) < 1.0
            raise 'The steps take up the whole stage. Reduce the number of steps, the overlap or the deck size.'
          end
        end
        region = inside ? Packer::Region.new(outer, holes) : nil
        tiers = Tiers.build(oriented, deck_d, overlap, steps, height, rects, o[:fascia] != 'none', inside, region)
        out[:steps] = steps
        out[:rise] = steps > 0 ? tiers[:rise] : nil
        out[:notes].concat(tiers[:notes])
        gap = tiers[:gaps].max
        if gap && gap > 0.5
          out[:notes] << "The stepped edge has #{Units.len(gap, sys)} left over after whole decks. " \
                         'It is split evenly at both ends of each step.'
        end
        unless tiers[:lines].empty?
          effort[:contact_edges] = tiers[:lines]
          effort[:finalists] = [effort[:finalists] || 1, 4].max
        end
        out[:tiers] = tiers
      end

      effort[:prefer_deck] = o[:default_deck] || rects.max_by(&:area)
      result = Packer.run(stage_outer, holes, pieces, effort)
      placed = result[:placed]
      raise 'No enabled block fits inside this boundary. Enable smaller blocks or enlarge the boundary.' if placed.empty?

      # Split the free space evenly at both ends, except across a stepped edge (decks must
      # stay flush against it). Only happens where every block still fits afterwards.
      sreg = Packer::Region.new(stage_outer, holes)
      th = Packer.dominant_angle(placed)
      [[Math.cos(th), Math.sin(th)], [-Math.sin(th), Math.cos(th)]].each do |u|
        next if oriented.any? { |ori| (ori[:n][0] * u[0] + ori[:n][1] * u[1]).abs > 0.5 }
        Packer.centre_along(placed, sreg, stage_outer, u)
      end

      paths = []
      if o[:fascia] != 'none'
        lines = tiers ? tiers[:lines] : []
        skip = lines.empty? ? nil : ->(a, c) { lines.any? { |ln| Tiers.along?(a, c, ln) } }
        paths = Perimeter.paths(placed, skip)
        paths.each do |pa|
          pa[:zb] = 0.0
          pa[:zt] = height
        end
        paths.concat(tiers[:fascia]) if tiers
      end

      stage_area = Packer.polygon_area(stage_outer) - holes.map { |h| Packer.polygon_area(h) }.sum
      if stage_area > 0 && result[:covered_area] / stage_area < 0.995
        fit = nearest_fit(stage_outer, holes, rects, sys)
        out[:notes] << fit if fit
      end
      out.merge!(stage_outer: stage_outer, result: result, placed: placed, paths: paths,
                 stage_area: stage_area, footprint: Packer.min_rect(placed.flat_map(&:pts)))
      out
    end

    # For a plain rectangle: which side lengths would tile exactly with these decks.
    def self.nearest_fit(outline, holes, rects, sys)
      return nil unless holes.empty? && outline.size == 4 && !rects.empty?
      4.times do |i|
        a = outline[i]
        b = outline[(i + 1) % 4]
        c = outline[(i + 2) % 4]
        d1 = [b[0] - a[0], b[1] - a[1]]
        d2 = [c[0] - b[0], c[1] - b[1]]
        l1 = Math.hypot(d1[0], d1[1])
        l2 = Math.hypot(d2[0], d2[1])
        return nil if l1 < 1e-6 || l2 < 1e-6 || (d1[0] * d2[0] + d1[1] * d2[1]).abs / (l1 * l2) > 0.02
      end
      base = Packer.deck_base(rects)
      return nil if base < 1.0
      msgs = []
      [Math.hypot(outline[1][0] - outline[0][0], outline[1][1] - outline[0][1]),
       Math.hypot(outline[2][0] - outline[1][0], outline[2][1] - outline[1][1])].each do |len|
        rem = len % base
        next if rem < 0.5 || base - rem < 0.5
        lo = len - rem
        hi = lo + base
        opts = []
        opts << Units.len(lo, sys) if lo > 0
        opts << Units.len(hi, sys)
        msgs << "a #{Units.len(len, sys)} side would tile fully at #{opts.join(' or ')}"
      end
      return nil if msgs.empty?
      "Part of the area is left uncovered because the size does not suit these decks: #{msgs.join('; ')}."
    end
  end
end
