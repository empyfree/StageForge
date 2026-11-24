# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module StageForge
  VERSION = '0.10.1'

  unless file_loaded?(__FILE__)
    ex = SketchupExtension.new('StageForge', 'stageforge/main')
    ex.description = 'Fill a drawn boundary with staging blocks (decks, triangles, quadrants, ' \
                     'semicircles, corners) and event seating (equal, offset, curved rows), choose make/model, height and fascia, and get a block list.'
    ex.version = VERSION
    ex.creator = 'StageForge'
    ex.copyright = '2026'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end
