D=File.expand_path('../stageforge', __dir__)
require File.join(D,'packer'); require File.join(D,'seating'); require File.join(D,'tables')
include StageForge
W=20*39.37; H=12*39.37
outer=[[0,0],[W,0],[W,H],[0,H]]; reg=Packer::Region.new(outer,[])
front={mid:[W/2,0.0],f:[0.0,1.0]}
[[60.0,'dining',10],[60.0,'dining',24],[60.0,'dining',40],[60.0,'dining',80],[72.0,'horseshoe',30]].each do |d,arr,n|
 %w[inline staggered bestfit].each do |lay|
  s=Tables.suggest(d,arr)
  prm={arrangement:arr,layout:lay,dia:d,seats:s[:seats],side:s[:spacing],row:s[:row_spacing],clearance:0.0,margin:1.0,chair_len:17.7,chair_wid:17.7,align:'center',aisles:[],count:n}
  t0=Time.now; r=Tables.run(reg,outer,front,prm)
  puts "#{d} #{arr} #{lay} want #{n}: got #{r[:tables].size} scale=#{r[:scale].round(2)} cap=#{r[:capacity]} nearest=#{(r[:nearest]||0).round(1)}in rows=#{r[:rows].map{|x|x[:tables]}.inspect} #{(Time.now-t0).round(1)}s #{r[:notes].first(1)}"
  raise 'count' unless r[:tables].size==n || r[:notes].any?{|x| x.start_with?('Only')}
 end
end
