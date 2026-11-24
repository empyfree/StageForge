# frozen_string_literal: true

require 'json'
require 'fileutils'

module StageForge
  # Formatting helpers for lengths and areas (internal SketchUp unit = inches).
  module Units
    def self.trim(x)
      format('%.2f', x).sub(/\.?0+\z/, '')
    end

    # Feet and inches to the nearest 1/16", e.g. 4', 2' 10 7/16", 6 1/2".
    # Rounding happens on the total first, so 47.9999 in reads 4' (not 3' 12").
    def self.imperial(inches)
      neg = inches < 0
      sixteenths = (inches.abs * 16).round
      ft = sixteenths / 192
      rem = sixteenths % 192
      whole = rem / 16
      frac = rem % 16
      f = nil
      if frac > 0
        g = frac.gcd(16)
        f = "#{frac / g}/#{16 / g}"
      end
      inch_txt = if whole.zero? && f
                   f
                 elsif f
                   "#{whole} #{f}"
                 else
                   whole.to_s
                 end
      txt = if ft.zero?
              "#{inch_txt}\""
            elsif whole.zero? && f.nil?
              "#{ft}'"
            else
              "#{ft}' #{inch_txt}\""
            end
      neg ? "-#{txt}" : txt
    end

    def self.metres(inches)
      format('%.2f m', inches * 0.0254)
    end

    # "28' x 12' (8.53 m x 3.66 m)" for quoting a stage in both systems.
    def self.both(w, h)
      "#{imperial(w)} \u00D7 #{imperial(h)} (#{metres(w)} \u00D7 #{metres(h)})"
    end

    def self.len(inches, system)
      if system == 'metric'
        mm = inches * 25.4
        mm >= 1000 ? "#{trim(mm / 1000.0)} m" : "#{mm.round} mm"
      else
        imperial(inches)
      end
    end

    def self.area(sq_in, system)
      if system == 'metric'
        "#{trim(sq_in * 0.00064516)} m\u00B2"
      else
        "#{trim(sq_in / 144.0)} ft\u00B2"
      end
    end

    # A catalog dimension (in the model's own dim_unit) as text, without suffix for mm.
    def self.dim(v, dim_unit)
      dim_unit == 'mm' ? v.to_f.round.to_s : imperial(v.to_f)
    end
  end

  module Catalog
    SHAPES = %w[rect tri quad semi chamfer poly].freeze

    def self.user_dir
      File.join(Dir.home, 'StageForge')
    end

    def self.user_file
      File.join(user_dir, 'user_catalog.json')
    end

    def self.read_json(path)
      JSON.parse(File.read(path, encoding: 'UTF-8'))
    end

    def self.block_label(blk, du)
      sfx = du == 'mm' ? ' mm' : ''
      d = ->(k) { Units.dim(blk[k], du) }
      case blk['shape']
      when 'rect' then "#{d.call('w')} \u00D7 #{d.call('h')}#{sfx}"
      when 'tri' then "Triangle #{d.call('w')} \u00D7 #{d.call('h')}#{sfx}"
      when 'quad' then "Quadrant R#{d.call('r')}#{sfx}"
      when 'semi' then "Semicircle R#{d.call('r')}#{sfx}"
      when 'chamfer' then "Corner #{d.call('w')} \u00D7 #{d.call('h')}, cut #{d.call('cut')}#{sfx}"
      else 'Custom shape'
      end
    end

    def self.merge!(base, extra)
      extra['makes'].to_a.each do |mk|
        existing = base['makes'].find { |m| m['name'] == mk['name'] }
        if existing.nil?
          base['makes'] << mk
        else
          mk['models'].to_a.each do |md|
            idx = existing['models'].index { |m| m['id'] == md['id'] }
            if idx
              existing['models'][idx] = md
            else
              existing['models'] << md
            end
          end
        end
      end
    end

    # Loads the shipped catalog, merges the user's, validates every block.
    def self.load
      cat = read_json(File.join(StageForge::DIR, 'catalog.json'))
      warnings = []
      if File.exist?(user_file)
        begin
          merge!(cat, read_json(user_file))
        rescue StandardError => e
          warnings << "Could not read #{user_file}: #{e.message}"
        end
      end
      cat['makes'].each do |mk|
        mk['models'].each do |md|
          md['units'] = md['units'].to_s == 'imperial' ? 'imperial' : 'metric'
          md['dim_unit'] ||= md['units'] == 'imperial' ? 'in' : 'mm'
          to_in = md['dim_unit'] == 'mm' ? 1.0 / 25.4 : 1.0
          good = []
          md['blocks'].to_a.each do |blk|
            begin
              blk['_label'] = block_label(blk, md['dim_unit'])
              blk['label'] = blk['_label']
              StageForge::Packer.build_piece(blk, to_in)
              good << blk
            rescue StandardError => e
              warnings << "#{mk['name']} / #{md['name']}: #{e.message} (block skipped)"
            end
          end
          md['blocks'] = good
          md['heights'] ||= []
          md['default_height'] ||= md['heights'].first
        end
        mk['models'].reject! { |md| md['blocks'].empty? }
      end
      cat['makes'].reject! { |mk| mk['models'].empty? }
      cat['warnings'] = warnings
      cat
    end

    def self.find_model(cat, id)
      cat['makes'].each do |mk|
        mk['models'].each { |md| return [mk, md] if md['id'] == id }
      end
      nil
    end

    TEMPLATE = <<~JSON
      {
        "makes": [
          {
            "name": "My Staging Company",
            "models": [
              {
                "id": "my-deck-system",
                "name": "My deck system",
                "units": "metric",
                "dim_unit": "mm",
                "leg_deduction": 25,
                "leg_size": 50,
                "hard_fascia_thickness": 18,
                "soft_pleat_pitch": 150,
                "heights": [400, 600, 800, 1000],
                "default_height": 600,
                "blocks": [
                  { "id": "d2x1", "name": "Deck 2 x 1 m", "shape": "rect", "w": 2000, "h": 1000, "enabled": true, "default": true },
                  { "id": "tri1", "name": "Triangle 1 m", "shape": "tri", "w": 1000, "h": 1000, "enabled": true },
                  { "id": "q1", "name": "Quadrant R1 m", "shape": "quad", "r": 1000, "enabled": false },
                  { "id": "s1", "name": "Semicircle R1 m", "shape": "semi", "r": 1000, "enabled": false },
                  { "id": "c1", "name": "Corner 1 m, cut 0.5 m", "shape": "chamfer", "w": 1000, "h": 1000, "cut": 500, "enabled": false },
                  { "id": "trap", "name": "Trapezoid (custom, convex)", "shape": "poly", "points": [[0,0],[2000,0],[1500,1000],[500,1000]], "enabled": false }
                ]
              }
            ]
          }
        ]
      }
    JSON

    # Creates the user catalog from a template if it does not exist; returns the folder.
    def self.ensure_user_file
      FileUtils.mkdir_p(user_dir)
      File.write(user_file, TEMPLATE, encoding: 'UTF-8') unless File.exist?(user_file)
      user_dir
    end
  end
end
