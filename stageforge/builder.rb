# frozen_string_literal: true

module StageForge
  # Turns a packing result into SketchUp geometry. Everything is created inside a
  # single group in the active context, in one undoable operation.
  module Builder
    COLORS = {
      deck: [74, 78, 86],
      leg: [150, 152, 158],
      hard: [30, 30, 34],
      soft: [20, 20, 26],
      proxy: [112, 134, 156],
      proxy_front: [52, 190, 202],
      table: [196, 164, 112]
    }.freeze

    def self.pt3(p, z)
      Geom::Point3d.new(p[0], p[1], z)
    end

    def self.material(model, key)
      name = "StageForge #{key}"
      m = model.materials[name] || model.materials.add(name)
      m.color = Sketchup::Color.new(*COLORS[key])
      m
    end

    def self.paint(ents, mat)
      ents.grep(Sketchup::Face).each do |f|
        f.material = mat
        f.back_material = mat
      end
    end

    # Builds a closed face from a polygon, using real curves for arc runs.
    def self.outline_face(ents, pts, arc, z)
      n = pts.size
      s = (0...n).find { |k| !arc[k] } || 0
      edges = []
      k = 0
      while k < n
        i = (s + k) % n
        if arc[i]
          run = [pt3(pts[i], z)]
          while k < n && arc[(s + k) % n]
            run << pt3(pts[(s + k + 1) % n], z)
            k += 1
          end
          edges.concat(ents.add_curve(run))
        else
          edges << ents.add_line(pt3(pts[i], z), pt3(pts[(i + 1) % n], z))
          k += 1
        end
      end
      ents.add_face(edges)
    end

    def self.extrude_up(face, height)
      face.reverse! if face.normal.z < 0
      face.pushpull(height)
    end

    def self.prism(ents, pts, arc, z, height)
      face = outline_face(ents, pts, arc, z)
      extrude_up(face, height)
    end

    def self.unit(v)
      l = Math.hypot(v[0], v[1])
      l < 1e-12 ? [1.0, 0.0] : [v[0] / l, v[1] / l]
    end

    # Centres (in the block's local plan) of the small corner legs.
    def self.leg_centres(piece, leg_size)
      pts = piece.local
      n = pts.size
      out = []
      n.times do |i|
        next if piece.arc[i] && piece.arc[i - 1]
        v = pts[i]
        a = pts[i - 1]
        b = pts[(i + 1) % n]
        ua = unit([a[0] - v[0], a[1] - v[1]])
        ub = unit([b[0] - v[0], b[1] - v[1]])
        bis = unit([ua[0] + ub[0], ua[1] + ub[1]])
        dot = [[ua[0] * ub[0] + ua[1] * ub[1], 1.0].min, -1.0].max
        half = Math.acos(dot) / 2.0
        next if half < 0.15
        dist = 0.75 * leg_size / Math.sin(half)
        dist = [dist, 0.45 * [piece.bw, piece.bh].min].min
        out << [v[0] + bis[0] * dist, v[1] + bis[1] * dist]
      end
      # A semicircle also gets a third leg under the middle of its curved edge.
      if piece.shape == 'semi'
        r = piece.bw / 2.0
        out << [r, r - leg_size] if r > leg_size * 2.0
      end
      out
    end

    # Floor level under each leg: 0 on the ground, or the top of a lower tier that the leg
    # stands on (leg lies inside that tier's footprint).
    def self.leg_bottoms(pl, centres, top, tiers)
      centres.map do |c|
        wp = Packer.world_pts([c], pl.m, pl.angle, pl.tx, pl.ty)[0]
        b = 0.0
        tiers.each do |tr|
          next unless tr[:top] < top - 1e-6 && tr[:top] > b
          b = tr[:top] if Packer.pip_state(wp, tr[:poly]) != :out
        end
        b
      end
    end

    # One block definition. style 'solid' = full-height solid; 'legs' = slab + corner legs.
    # bottoms: per-leg floor level (0 = ground; higher where a leg bears on a lower tier).
    def self.definition_for(model, piece, top, style, thick, leg_size, centres, bottoms)
      bearing = bottoms.any? { |b| b > 0.01 } ? ' (bearing legs)' : ''
      defn = model.definitions.add("StageForge #{piece.name} H#{(top * 25.4).round}mm#{bearing}")
      ents = defn.entities
      if style == 'legs' && top > thick + 0.5
        slab_z = top - thick
        sg = ents.add_group
        prism(sg.entities, piece.local, piece.arc, slab_z, thick)
        paint(sg.entities, material(model, :deck))
        sg.name = 'Deck'
        lg = ents.add_group
        centres.each_with_index do |c, i|
          lh = slab_z - bottoms[i]
          next if lh < 0.05
          h = leg_size / 2.0
          z = bottoms[i]
          sq = [[c[0] - h, c[1] - h], [c[0] + h, c[1] - h], [c[0] + h, c[1] + h], [c[0] - h, c[1] + h]]
          face = lg.entities.add_face(sq.map { |p| pt3(p, z) })
          extrude_up(face, lh)
        end
        paint(lg.entities, material(model, :leg))
        lg.name = 'Legs'
      else
        prism(ents, piece.local, piece.arc, 0, top)
        paint(ents, material(model, :deck))
      end
      defn
    end

    # ---------------- fascia ----------------
    # Mitred outward offset of a path (outside = right-hand side of the walking direction).
    def self.offset_path(pts, d, closed)
      n = pts.size
      Array.new(n) do |i|
        if !closed && (i.zero? || i == n - 1)
          a, b = i.zero? ? [pts[0], pts[1]] : [pts[n - 2], pts[n - 1]]
          u = unit([b[0] - a[0], b[1] - a[1]])
          [pts[i][0] + u[1] * d, pts[i][1] - u[0] * d]
        else
          p0 = pts[i - 1]
          p1 = pts[i]
          p2 = pts[(i + 1) % n]
          u0 = unit([p1[0] - p0[0], p1[1] - p0[1]])
          u1 = unit([p2[0] - p1[0], p2[1] - p1[1]])
          n0 = [u0[1], -u0[0]]
          n1 = [u1[1], -u1[0]]
          k = 1.0 + n0[0] * n1[0] + n0[1] * n1[1]
          k = 0.1 if k < 0.1
          mx = (n0[0] + n1[0]) / k
          my = (n0[1] + n1[1]) / k
          ml = Math.hypot(mx, my)
          if ml > 3.0
            mx *= 3.0 / ml
            my *= 3.0 / ml
          end
          [p1[0] + mx * d, p1[1] + my * d]
        end
      end
    end

    # paths: [{ pts:, closed:, zb:, zt: }] with zb/zt relative to the stage floor.
    def self.hard_fascia(model, parent_ents, paths, z0, thickness)
      mesh = Geom::PolygonMesh.new
      paths.each do |pa|
        pts = pa[:pts]
        next if pts.size < 2
        off = offset_path(pts, thickness, pa[:closed])
        n = pts.size
        last = pa[:closed] ? n - 1 : n - 2
        zb = z0 + pa[:zb]
        zt = z0 + pa[:zt]
        next if zt - zb < 0.05
        (0..last).each do |i|
          j = (i + 1) % n
          a = pts[i]
          b = pts[j]
          oa = off[i]
          ob = off[j]
          mesh.add_polygon(pt3(oa, zb), pt3(ob, zb), pt3(ob, zt), pt3(oa, zt))
          mesh.add_polygon(pt3(a, zb), pt3(a, zt), pt3(b, zt), pt3(b, zb))
          mesh.add_polygon(pt3(a, zt), pt3(oa, zt), pt3(ob, zt), pt3(b, zt))
          mesh.add_polygon(pt3(a, zb), pt3(b, zb), pt3(ob, zb), pt3(oa, zb))
        end
      end
      g = parent_ents.add_group
      g.name = 'Hard fascia'
      m = material(model, :hard)
      g.entities.add_faces_from_mesh(mesh, 0, m, m)
      g
    end

    def self.soft_fascia(model, parent_ents, paths, z0, pitch)
      mesh = Geom::PolygonMesh.new
      depth = pitch * 0.5
      paths.each do |pa|
        pts = pa[:pts]
        next if pts.size < 2
        n = pts.size
        last = pa[:closed] ? n - 1 : n - 2
        zb = z0 + pa[:zb] + (pa[:zb] < 0.01 ? 0.5 : 0.0) # hangs just clear of the floor
        zt = z0 + pa[:zt]
        next if zt - zb < 0.05
        (0..last).each do |i|
          a = pts[i]
          b = pts[(i + 1) % n]
          dx = b[0] - a[0]
          dy = b[1] - a[1]
          len = Math.hypot(dx, dy)
          next if len < 1e-6
          nx = dy / len
          ny = -dx / len
          pleats = len < pitch * 0.75 ? 1 : [(len / pitch / 2.0).round * 2, 2].max
          line = (0..pleats).map do |k|
            off = pleats > 1 && k.odd? ? depth : 0.0
            [a[0] + dx * k / pleats + nx * off, a[1] + dy * k / pleats + ny * off]
          end
          line.each_cons(2) do |p, q|
            mesh.add_polygon(pt3(p, zb), pt3(q, zb), pt3(q, zt), pt3(p, zt))
          end
        end
      end
      g = parent_ents.add_group
      g.name = 'Soft fascia (pleated)'
      m = material(model, :soft)
      g.entities.add_faces_from_mesh(mesh, 0, m, m)
      g
    end

    # ---------------- main entry ----------------
    # boundary: { z: }, placed: [Packer::Placed]
    # prm: :height :style :fascia :deck_thickness (= leg deduction: legs are this much shorter
    #      than the finished height, and the modelled deck slab is this thick) :leg_size :hard_t :pitch :name :meta
    #      :tiers  [{ top:, poly:, placed: }]   :paths [{ pts:, closed:, zb:, zt: }]
    def self.build(model, boundary, placed, prm)
      model.start_operation('StageForge: generate stage', true)
      begin
        ents = model.active_entities
        stage = ents.add_group
        stage.name = prm[:name]
        z0 = boundary[:z]
        tiers = prm[:tiers] || []
        cache = {}
        tally = Hash.new(0) # [leg length (in), bearing on a lower deck?] => count
        origin = Geom::Point3d.new(0, 0, 0)
        zaxis = Geom::Vector3d.new(0, 0, 1)

        place = lambda do |pl, top, style|
          centres = leg_centres(pl.piece, prm[:leg_size])
          bottoms = leg_bottoms(pl, centres, top, tiers)
          slab_under = top - prm[:deck_thickness]
          bottoms.each do |bt|
            len = slab_under - bt
            tally[[len.round(3), bt > 0.01]] += 1 if len >= 0.05
          end
          key = [pl.piece.id, top.round(2), style, bottoms.map { |b| b.round(2) }]
          cache[key] ||= definition_for(model, pl.piece, top, style, prm[:deck_thickness],
                                        prm[:leg_size], centres, bottoms)
          tr = Geom::Transformation.new(Geom::Point3d.new(pl.tx, pl.ty, z0)) *
               Geom::Transformation.rotation(origin, zaxis, pl.angle) *
               Geom::Transformation.scaling(pl.m == 1 ? -1.0 : 1.0, 1.0, 1.0)
          stage.entities.add_instance(cache[key], tr)
        end

        placed.each { |pl| place.call(pl, prm[:height], prm[:style]) }
        tiers.each do |t|
          t[:placed].each { |pl| place.call(pl, t[:top], 'legs') }
        end

        paths = prm[:paths] || []
        unless paths.empty?
          case prm[:fascia]
          when 'hard' then hard_fascia(model, stage.entities, paths, z0, prm[:hard_t])
          when 'soft' then soft_fascia(model, stage.entities, paths, z0, prm[:pitch])
          end
        end
        stage.set_attribute('StageForge', 'settings', JSON.generate(prm[:meta] || {}))
        model.selection.clear
        model.selection.add(stage)
        model.commit_operation
        [stage, tally]
      rescue StandardError
        model.abort_operation
        raise
      end
    end
  end
end
