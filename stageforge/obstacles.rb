# frozen_string_literal: true

module StageForge
  # Things in the model that stand in the way of chairs. An object blocks the chairs under its
  # footprint if any part of it lies within a chosen height band above the seating area's floor
  # (default 100 mm to about chair height). Flat things at floor level (ground, paths, rugs,
  # floor-level aisle markers) fall below the band and do not block; overhead items fall above it.
  # The geometry rules are pure Ruby; only `gather` touches the SketchUp API.
  module Obstacles
    DEFAULT_LO = 100.0 / 25.4  # inches above the floor: default bottom of the avoided band
    DEFAULT_HI = 1100.0 / 25.4 # default top of the avoided band
    MAX_POLYS = 40          # more than this many footprints for one object: use its outline
    TAG = 'StageForge'

    # faces: [[ [x,y,z], ... ], ...] (world coordinates of one object's faces).
    # ctx: { z0: floor level, lo:, hi: (band above the floor), area: [minx,miny,maxx,maxy], gap: }
    # Returns CCW footprint polygons (already widened by the gap), or [].
    def self.footprints(faces, ctx)
      return [] if faces.empty?
      zs = faces.flat_map { |f| f.map { |p| p[2] } }
      return [] if zs.max <= ctx[:z0] + ctx[:lo]  # never rises into the band
      return [] if zs.min >= ctx[:z0] + ctx[:hi]  # entirely above the band
      polys = []
      faces.each do |f|
        next if f.map { |p| p[2] }.max <= ctx[:z0] + ctx[:lo]
        xy = f.map { |p| [p[0], p[1]] }
        next if xy.size < 3
        a = Packer.signed_area(xy)
        next if a.abs < 1.0
        xy = xy.reverse if a < 0
        polys << xy
      end
      return [] if polys.empty?
      if polys.size > MAX_POLYS
        h = Packer.hull(polys.flatten(1))
        polys = h.size >= 3 ? [h] : []
      end
      polys = polys.select { |xy| overlaps_area?(xy, ctx) }
      polys.map { |xy| widen(xy, ctx[:gap]) }
    end

    # objs: [{ name:, faces: }] from gather. Returns [{ name:, polys: }] that block this bank.
    def self.for_bank(objs, ctx)
      out = []
      objs.each do |o|
        polys = footprints(o[:faces], ctx)
        out << { name: o[:name], polys: polys } unless polys.empty?
      end
      out
    end

    # A comparable fingerprint of what blocks (used to notice an object moving).
    def self.signature(found)
      found.flat_map { |o| o[:polys] }.map { |xy| xy.map { |p| [p[0].round(2), p[1].round(2)] }.inspect }.sort
    end

    def self.overlaps_area?(xy, ctx)
      xs = xy.map { |p| p[0] }
      ys = xy.map { |p| p[1] }
      g = ctx[:gap] || 0.0
      a = ctx[:area]
      !(xs.max < a[0] - g || xs.min > a[2] + g || ys.max < a[1] - g || ys.min > a[3] + g)
    end

    # Pushes a CCW polygon outwards by gap (mitred; corners are capped).
    def self.widen(xy, gap)
      return xy unless gap && gap > 0.01
      n = xy.size
      Array.new(n) do |i|
        p0 = xy[i - 1]
        p1 = xy[i]
        p2 = xy[(i + 1) % n]
        u0 = unit([p1[0] - p0[0], p1[1] - p0[1]])
        u1 = unit([p2[0] - p1[0], p2[1] - p1[1]])
        n0 = [u0[1], -u0[0]]
        n1 = [u1[1], -u1[0]]
        k = [1.0 + n0[0] * n1[0] + n0[1] * n1[1], 0.2].max
        mx = (n0[0] + n1[0]) / k
        my = (n0[1] + n1[1]) / k
        ml = Math.hypot(mx, my)
        if ml > 2.5
          mx *= 2.5 / ml
          my *= 2.5 / ml
        end
        [p1[0] + mx * gap, p1[1] + my * gap]
      end
    end

    def self.unit(v)
      l = Math.hypot(v[0], v[1])
      l < 1e-12 ? [1.0, 0.0] : [v[0] / l, v[1] / l]
    end

    # ---------------- SketchUp traversal ----------------
    def self.world_bounds(bb, tr)
      pts = (0..7).map { |i| tr * bb.corner(i) }
      [pts.map(&:x).min, pts.map(&:y).min, pts.map(&:x).max, pts.map(&:y).max]
    end

    def self.visible?(e)
      return false if e.respond_to?(:hidden?) && e.hidden?
      return false if e.respond_to?(:layer) && e.layer && !e.layer.visible?
      true
    end

    def self.excluded?(e, skip)
      return true if skip.include?(e)
      return true if e.get_attribute(TAG, 'set_id') || e.get_attribute(TAG, 'aisle') || e.get_attribute(TAG, 'ignore')
      false
    end

    def self.label(e)
      n = e.name.to_s
      n = e.definition.name.to_s if n.empty? && e.respond_to?(:definition)
      n.empty? ? 'object' : n
    end

    # Walks the model's active context. Returns [{ name:, faces: }] for every visible object
    # near `area` ([minx,miny,maxx,maxy], already widened by any gap). skip: entities to leave
    # out (the seating areas' own floors).
    def self.gather(model, area, skip)
      out = []
      walk(model.active_entities, Geom::Transformation.new, area, skip, out, '(loose geometry)')
      out
    end

    def self.walk(ents, tr, area, skip, out, name)
      faces = []
      ents.each do |e|
        next unless visible?(e)
        case e
        when Sketchup::Face
          next if skip.include?(e)
          faces << e.outer_loop.vertices.map { |v| p = tr * v.position; [p.x.to_f, p.y.to_f, p.z.to_f] }
        when Sketchup::Group, Sketchup::ComponentInstance
          next if excluded?(e, skip)
          bb = world_bounds(e.bounds, tr)
          next if bb[2] < area[0] || bb[0] > area[2] || bb[3] < area[1] || bb[1] > area[3]
          sub = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
          walk(sub, tr * e.transformation, area, skip, out, label(e))
        end
      end
      out << { name: name, faces: faces } unless faces.empty?
    end
  end
end
