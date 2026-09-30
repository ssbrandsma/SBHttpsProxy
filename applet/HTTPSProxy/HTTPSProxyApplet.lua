local oo=require("loop.simple")
local Applet=require("jive.Applet")
local Framework=require("jive.ui.Framework")
local Service=require("applets.HTTPSProxy.HTTPSProxyService")
module(...);oo.class(_M,Applet)
function init(self) self._root="/usr/share/jive/applets/HTTPSProxy";self.service=Service();self.service:init(self);self.service:start() end
function free(self) self.service:stop();return true end
return _M
