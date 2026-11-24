D=File.expand_path('../stageforge', __dir__)
require File.join(D,'packer'); require File.join(D,'seating'); require File.join(D,'tables')
include StageForge
W=20*39.37; H=12*39.37
outer=[[0,0],[W,0],[W,H],[0,H]]; reg=Packer::Region.new(outer,[])
front={mid:[W/2,0.0],f:[0.0,1.0]}
s=Tables.suggest(72.0,'horseshoe')
base={arrangement:'horseshoe',layout:'inline',dia:72.0,seats:8,side:s[:spacing],row:s[:row_spacing],clearance:0.0,margin:1.0,chair_len:17.7,chair_wid:17.7,align:'center',aisles:[]}
[nil,[W/2,-120.0]].each do |fc|
 [200.0,270.0,360.0,120.0].each do |arc|
  t0=Time.now; r=Tables.run(reg,outer,front,base.merge(arc:arc,focal:fc))
  puts "focal=#{fc ? 'stage':'parallel'} arc=#{arc}: #{r[:tables].size} tables #{r[:seats].size} seats #{(Time.now-t0).round(2)}s #{r[:notes].first(1)}"
 end
end
r=Tables.run(reg,outer,front,base.merge(arc:200.0,focal:[W/2,-120.0],count:12))
tb=r[:tables].min_by{|t|t.x}; sts=r[:seats].select{|x|x.table==r[:tables].index(tb)}
puts "left-most table facing: #{sts.first.dx.round(2)},#{sts.first.dy.round(2)} (should point right/down towards stage)"
puts "count12: #{r[:tables].size} scale=#{r[:scale].round(2)} nearest=#{r[:nearest].round(1)}"
