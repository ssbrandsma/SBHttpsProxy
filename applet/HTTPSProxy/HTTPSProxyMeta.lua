local oo=require("loop.simple");local AppletMeta=require("jive.AppletMeta");local appletManager=appletManager
module(...);oo.class(_M,AppletMeta)
function jiveVersion() return 1,1 end
function registerApplet() local a=appletManager:loadApplet("HTTPSProxy"); if a and a.service then return a.service end end
