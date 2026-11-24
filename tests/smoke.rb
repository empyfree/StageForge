$LOAD_PATH.unshift File.join(__dir__, 'stub')
require 'sketchup.rb'
root = File.expand_path('..', __dir__)
load File.join(root, 'stageforge.rb')
load File.join(root, 'stageforge/main.rb')

class FakeDlg
  attr_reader :calls
  def initialize; @calls = []; end
  def execute_script(s); @calls << s; end
end
dlg = FakeDlg.new
StageForge.instance_variable_set(:@dlg, dlg)
StageForge::SeatingUI.instance_variable_set(:@dlg, dlg)

k = 1 / 25.4
w = 9000 * k; h = 4000 * k
StageForge.instance_variable_set(:@boundary, { src: Dummy.new('src'), outer: [[0,0],[w,0],[w,h],[0,h]], holes: [], z: 0.0,
  bb: [0,0,w,h], area: w*h })
StageForge.instance_variable_set(:@tier_edges, [[[0,0],[w,0]]])

cat = StageForge::Catalog.load
puts "catalog warnings: #{cat['warnings'].inspect}"
imp = cat['makes'][0]['models'][1]
enabled = imp['blocks'].select { |b| b['enabled'] }.map { |b| b['id'] }

pass = 0
[['legs','hard','metric'],['solid','none','imperial'],['legs','soft','metric']].each do |style, fascia, display|
  dlg.calls.clear
  StageForge.run_generate({ 'model' => imp['id'], 'display' => display, 'height' => 900 * k, 'fascia' => fascia, 'style' => style,
    'effort' => 'fast', 'enabled' => enabled, 'default_deck' => 'r96x48', 'tier_overlap' => nil, 'tier_rise' => nil,
    'tier_inside' => false, 'tier_steps' => nil, 'leg_deduction' => nil })
  res = dlg.calls.find { |c| c.start_with?('SF.onResult') }
  raise 'no result pushed' unless res
  r = JSON.parse(res[/\((.*)\)\z/m, 1])
  puts "stage #{style}/#{fascia}/#{display}: blocks=#{r['total_blocks']} legs=#{r['total_legs']} steps=#{r['steps']} cov=#{r['coverage']}%"
  puts "   quote: #{r['quote']}"
  puts "   notes: #{r['notes'].first(2)}"
  pass += 1
end
# inside steps + override
dlg.calls.clear
StageForge.run_generate({ 'model' => imp['id'], 'display' => 'metric', 'height' => 900 * k, 'fascia' => 'hard', 'style' => 'legs',
  'effort' => 'fast', 'enabled' => enabled, 'default_deck' => 'r96x48', 'tier_inside' => true, 'tier_steps' => 2 })
r = JSON.parse(dlg.calls.find { |c| c.start_with?('SF.onResult') }[/\((.*)\)\z/m, 1])
puts "inside, 2 steps: steps=#{r['steps']} rise=#{r['rise']} cov=#{r['coverage']}% legs=#{r['total_legs']}"
pass += 1

# ---------- seating (banks + shared aisles) ----------
S = StageForge::SeatingUI
k = 1 / 25.4
class FakeEnt < Dummy
  attr_accessor :poly, :pid
  def initialize(poly, pid); super('ent'); @poly = poly; @pid = pid; @tags = {}; end
  def valid?; true; end
  def persistent_id; @pid; end
  def get_attribute(_d, key, _def = nil); @tags[key]; end
  def set_attribute(_d, key, v); @tags[key] = v; end
  def delete_attribute(_d, key); @tags.delete(key); end
end
def StageForge.horizontal_faces(e); [[e, nil]]; end
def StageForge.face_polygon(f, _t); { outer: f.poly }; end
def StageForge.boundary_from_source(src, _pids = nil, _model = nil)
  o = src.poly
  { src: src, outer: o, holes: [], z: 0.0, bb: Packer_bbox(o), area: (o[1][0]-o[0][0])*(o[2][1]-o[1][1]) }
end
def Packer_bbox(o); [o.map{|p|p[0]}.min, o.map{|p|p[1]}.min, o.map{|p|p[0]}.max, o.map{|p|p[1]}.max]; end
rect = ->(x0, y0, x1, y1) { [[x0*k,y0*k],[x1*k,y0*k],[x1*k,y1*k],[x0*k,y1*k]] }
areaA = FakeEnt.new(rect.(0,0,6000,4000), 1)
areaB = FakeEnt.new(rect.(10000,0,16000,4000), 2)
aisle = FakeEnt.new(rect.(2900,0,3100,4000), 3)
chair = { defn: Dummy.new('chair'), name: 'Chair', sx: 1.0, sy: 1.0, sz: 1.0, minx: 0.0, maxx: 18.0, miny: 0.0, maxy: 18.0, minz: 0.0, maxz: 36.0 }
base = { 'units'=>'metric','mode'=>'equal','show'=>'boxes','side'=>570,'row'=>1100,'clearance'=>0,'margin'=>0,
         'facing'=>'+x','align'=>'center','stagger'=>false,'focal_source'=>'front','radius'=>nil }
S.instance_variable_set(:@dlg, dlg)
def S.mk(id, name, src, chair, front)
  b = S::Bank.new(id, name); b.boundary = { src: src }; b.boundary_pid = src.pid; b.chair = chair; b.front = front
  b
end
frontA = { kind: 'line', p1: [0.0, 4200*k], p2: [6000*k, 4200*k] }
frontB = { kind: 'line', p1: [10000*k, 4200*k], p2: [16000*k, 4200*k] }
a = S.mk('bankA', 'Bank 1', areaA, chair, frontA)
b = S.mk('bankB', 'Bank 2', areaB, chair, frontB)
S.instance_variable_set(:@banks, [])
S.instance_variable_set(:@cur, a)
S.run_generate(base.dup); puts "bank A placed: #{a.chairs} chairs"
S.instance_variable_set(:@cur, b)
S.run_generate(base.merge('mode' => 'offset')); puts "bank B placed: #{b.chairs} chairs (#{b.mode})"
raise 'banks not registered' unless S.instance_variable_get(:@banks).size == 2

# mark an aisle that overlaps only bank A
S.instance_variable_set(:@aisles, [aisle])
S.instance_variable_set(:@aisle_sigs, {})
calls = []
orig = S.method(:lay_out)
S.define_singleton_method(:lay_out) { |bk, s, **o| calls << bk.name; orig.call(bk, s, **o) }
before = a.chairs
S.process_changes(false)
puts "after marking aisle: relaid #{calls.inspect}; bank A chairs #{before} -> #{a.chairs}"
raise 'wrong banks relaid' unless calls == ['Bank 1']
raise 'aisle did not clear chairs' unless a.chairs < before
# widen the aisle: only A again
calls.clear; aisle.poly = rect.(2800,0,3300,4000)
before = a.chairs; S.process_changes(true)
puts "after widening: relaid #{calls.inspect}; A #{before} -> #{a.chairs}"
raise unless calls == ['Bank 1']
# nothing changed: nothing relaid
calls.clear; S.process_changes(true); puts "no change: relaid #{calls.inspect}"
raise unless calls.empty?
# move aisle over bank B only
calls.clear; aisle.poly = rect.(12900,0,13100,4000)
S.process_changes(true); puts "aisle moved to B: relaid #{calls.sort.inspect}"
raise unless calls.sort == ['Bank 1', 'Bank 2']   # leaves A (changed) and enters B
# edit bank B's own area
calls.clear; areaB.poly = rect.(10000,0,15000,4000)
S.process_changes(true); puts "B area edited: relaid #{calls.inspect}"
raise unless calls == ['Bank 2']
# copy-settings new bank
nb = S.new_bank(b); puts "new bank copies: mode=#{nb.params['mode']} chair=#{!nb.chair.nil?} boundary=#{nb.boundary.inspect}"
# payload round trip
pay = JSON.parse(JSON.generate(S.bank_payload(b)))
puts "payload ok: #{pay['id']} #{pay['params']['mode']}"
# show swap
S.show_all('chair'); puts 'show_all ok'
# obstacles: a table in bank A's area removes chairs; avoid=false ignores it; moving it re-lays only A
table_poly = rect.(1500,1500,2500,2500)
table = Struct.new(:poly).new(table_poly)
StageForge::Obstacles.define_singleton_method(:gather) { |_m, _a, _s| [{ name: 'Table', faces: [table.poly.map { |p| [p[0], p[1], 30.0] }, table.poly.map { |p| [p[0], p[1], 0.0] }] }] }
pushed = []
S.define_singleton_method(:push) { |fn, obj = nil| pushed << [fn, obj] }
S.instance_variable_set(:@aisles, [])
S.instance_variable_set(:@cur, a)
a.params = base.dup
S.lay_out(a, base.merge('avoid' => true), live: false, transparent: false)
withobj = a.chairs
res = pushed.select { |fn, _| fn == 'onResult' }.last[1]
puts "note: #{res[:notes].first}"
S.lay_out(a, base.merge('avoid' => false), live: false, transparent: false)
without = a.chairs
puts "bank A with table avoided: #{withobj}; avoidance off: #{without}"
raise 'table did not remove chairs' unless withobj < without
# band excludes the table when set above it (table is 30 in = 762 mm tall)
S.lay_out(a, base.merge('avoid' => true, 'avoid_lo' => 900, 'avoid_hi' => 2000), live: false, transparent: false)
raise 'band above the table should not avoid it' unless a.chairs == without
puts "band 900-2000 mm ignores a 760 mm table: #{a.chairs} chairs"
# live: the object moves -> only the bank it was/is in re-lays
a.params = base.merge('avoid' => true)
S.lay_out(a, a.params, live: false, transparent: false)
b.params = base.merge('mode' => 'offset', 'avoid' => true)
S.lay_out(b, b.params, live: false, transparent: false)
S.instance_variable_set(:@aisle_sigs, {})
calls.clear
S.process_changes(true); puts "no movement: #{calls.inspect}"; raise unless calls.empty?
table.poly = rect.(1800,1500,2800,2500)
S.process_changes(true); puts "table moved within A: #{calls.inspect}"; raise unless calls == ['Bank 1']
calls.clear
table.poly = rect.(12000,1500,13000,2500)
S.process_changes(true); puts "table moved into B's area: #{calls.sort.inspect}"
raise unless calls.include?('Bank 2')
puts 'SMOKE PASSED (stage + banks + obstacles + live objects)'

# ---- table plans ----
tb = S.mk('bankT', 'Bank T', FakeEnt.new(rect.(0,0,12000,8000), 9), nil, { kind: 'line', p1: [0.0, 8200*k], p2: [12000*k, 8200*k] })
S.instance_variable_set(:@cur, tb); S.instance_variable_set(:@aisles, []); S.instance_variable_set(:@banks, [])
StageForge::Obstacles.define_singleton_method(:gather) { |_m, _a, _s| [] }
tp = base.merge('kind'=>'tables','t_dia'=>60,'t_seats'=>6,'t_arr'=>'dining','t_layout'=>'inline','t_side'=>3000,'t_row'=>3000)
pushed2 = []; S.define_singleton_method(:push) { |fn, obj = nil| pushed2 << [fn, obj] }
%w[inline staggered bestfit].each do |lay|
  %w[dining horseshoe].each do |arr|
    S.lay_out(tb, tp.merge('t_layout'=>lay, 't_arr'=>arr, 't_seats'=>(arr=='dining' ? 6 : 5)), live: false, transparent: false)
    puts "tables #{lay}/#{arr}: #{tb.tables} tables, #{tb.chairs} guests, label=#{S.bank_label(tb)}"
    raise 'no tables' unless tb.tables.to_i > 0 && tb.chairs == tb.tables * (arr=='dining' ? 6 : 5)
  end
end
r = pushed2.select { |f, _| f == 'onResult' }.last[1]; puts "result keys ok: #{r[:kind]} #{r[:tables]} #{r[:rows]}"
S.show_all('chair'); puts 'tables show_all ok'
tb.params = tp; pay = JSON.parse(JSON.generate(S.bank_payload(tb))); raise unless pay['params']['kind']=='tables'
puts 'TABLES PASSED'

# ---- fixed count, arc, stage-facing ----
%w[inline staggered bestfit].each do |lay|
  S.lay_out(tb, tp.merge('t_layout'=>lay,'t_arr'=>'horseshoe','t_seats'=>5,'t_count'=>14,'t_arc'=>240,'t_face'=>'centre'), live: false, transparent: false)
  r = pushed2.select { |f, _| f == 'onResult' }.last[1]
  puts "fixed count #{lay}: #{tb.tables} tables (wanted 14), spacing #{r[:spacing]}, capacity #{r[:capacity]}"
  raise 'count mismatch' unless tb.tables == 14
end
puts 'FIXED COUNT PASSED'
