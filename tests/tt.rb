D='/home/claude/stageforge_build/stageforge'
require File.join(D,'packer'); require File.join(D,'seating'); require File.join(D,'tables')
include StageForge
W=20*39.37; H=12*39.37
outer=[[0,0],[W,0],[W,H],[0,H]]
reg=Packer::Region.new(outer,[])
front={mid:[W/2,0.0],f:[0.0,1.0]}
def chk(r,prm,outer,reg)
  t=r[:tables]; sp=prm[:dia]
  min=Float::INFINITY
  t.each_with_index{|a,i| t.each_with_index{|b,j| next if j<=i; d=Math.hypot(a.x-b.x,a.y-b.y); min=d if d<min}}
  ins=r[:tables].all?{|a| Tables.ok?(r[:hull],a.x,a.y,reg,[])}
  [t.size, r[:seats].size, min.round(1), ins, r[:notes]]
end
[60.0,66.0,72.0].each do |d|
 %w[dining horseshoe].each do |arr|
  %w[inline staggered bestfit].each do |lay|
   s=Tables.suggest(d,arr)
   prm={arrangement:arr,layout:lay,dia:d,seats:s[:seats],side:s[:spacing],row:s[:row_spacing],clearance:0.0,margin:1.0,chair_len:17.7,chair_wid:17.7,align:'centre',aisles:[],max_seconds:4}
   t0=Time.now; r=Tables.run(reg,outer,front,prm)
   puts "#{d} #{arr} #{lay}: #{chk(r,prm,outer,reg).inspect} rows=#{r[:rows].map{|x|x[:tables]}.inspect} #{(Time.now-t0).round(2)}s"
  end
 end
end
# seat checks
s=Tables.seat_slots('horseshoe',60.0,5,17.7,[0.0,1.0]); p s.map{|a|a.map{|v|v.round(1)}}
s=Tables.seat_slots('dining',60.0,6,17.7,[0.0,1.0]); p s.map{|a|a.map{|v|v.round(1)}}
