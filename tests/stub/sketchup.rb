# Minimal stand-in for the SketchUp API: records calls, returns permissive dummies.
$LOG = []
class Dummy
  def initialize(name = 'd'); @name = name; end
  def method_missing(m, *a, &b)
    $LOG << "#{@name}.#{m}"
    return [] if m == :grep
    return self if %i[each select map].include?(m) && b.nil?
    Dummy.new("#{@name}.#{m}")
  end
  def respond_to_missing?(*) = true
  def to_ary; []; end
  def valid?; true; end
  def [](k); Dummy.new("#{@name}[]"); end
  def nil?; false; end
  def normal; Struct.new(:z, :x).new(1.0, 0.0); end
end
$FILES = {}
def file_loaded?(f); $FILES[f]; end
def file_loaded(f); $FILES[f] = true; end
module Geom
  class Point3d; def initialize(*a); @a=a; end; end
  class Vector3d; def initialize(*a); end; end
  class Transformation
    def initialize(*a); end
    def *(o); self; end
    def self.rotation(*a); new; end
    def self.scaling(*a); new; end
    def xscale; 1.0; end; def yscale; 1.0; end; def zscale; 1.0; end
  end
  class PolygonMesh < Dummy; end
end
module Sketchup
  class Entity < Dummy; end
  class Face < Entity; end
  class Group < Entity; end
  class ComponentInstance < Entity; end
  class Edge < Entity; end
  class EntityObserver; end
  class ModelObserver; end
  class SelectionObserver; end
  class InputPoint; def initialize; end; end
  class Color; def initialize(*a); end; end
  def self.register_extension(*a); end
  def self.read_default(*a); ''; end
  def self.write_default(*a); end
  def self.active_model; $MODEL ||= Dummy.new('model'); end
  def self.status_text=(x); end
end
class SketchupExtension
  attr_accessor :description, :version, :creator, :copyright
  def initialize(*a); end
end
module UI
  def self.menu(*a); Dummy.new('menu'); end
  def self.start_timer(*a, &b); b.call if b; 1; end
  def self.stop_timer(*a); end
  def self.messagebox(*a); end
  class HtmlDialog; end
end
