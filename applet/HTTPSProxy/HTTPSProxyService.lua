local io, os, tonumber, tostring, type = io, os, tonumber, tostring, type
local oo = require("loop.simple")
local Timer = require("jive.ui.Timer")
local SocketHttp = require("jive.net.SocketHttp")
local RequestHttp = require("jive.net.RequestHttp")
local lfs = require("lfs")
local log = require("jive.utils.log").logger("HTTPSProxy")
local jnt = jnt
module(...)
oo.class(_M)
local PORT=8765
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
function init(self, applet) self.applet=applet; self.root=applet._root; self.bin=self.root.."/bin/sbproxy"; self.pid="/tmp/httpsproxy.pid"; self.available=false end
function proxyUrl(_,url) if type(url)~="string" or not url:match("^https://") then return url end return "http://127.0.0.1:"..PORT.."/https/"..url:sub(9) end
function isAvailable(self) return self.available==true end
function getVersion(self) return self.version end
function _pidRunning(self) local f=io.open(self.pid,"r");if not f then return false end;local p=tonumber(f:read("*l"));f:close();return p and os.execute("kill -0 "..p.." 2>/dev/null") == 0 end
function _health(self, cb) local r=RequestHttp(function(data,err) local ok=data and data:match("status: OK");self.available=ok~=nil;if ok then self.version=data:match("sbproxy[^\n]*") end;if cb then cb(self.available,err) end end,"GET","/health",{headers={Connection="close"}});local h=SocketHttp(jnt,"127.0.0.1",PORT,"HTTPSProxyHealth");h:fetch(r) end
function start(self)
 if self:_pidRunning() then self:_health();return true end
 if not lfs.attributes(self.bin,"mode") then log:error("missing helper: ",self.bin);return false end
 os.execute("chmod 755 "..q(self.bin))
 local cmd="( "..q(self.bin).." --listen 127.0.0.1:8765 --ca-bundle "..q(self.root.."/certs/cacert.pem").." >>/tmp/httpsproxy.log 2>&1 & echo $! >"..q(self.pid).." )"
 os.execute(cmd); Timer(300,function() self:_health() end,true):start(); return true
end
function stop(self) os.execute("test -s "..q(self.pid).." && kill `cat "..q(self.pid).."` 2>/dev/null; rm -f "..q(self.pid));self.available=false end
function restart(self) self:stop();Timer(300,function() self:start() end,true):start();return true end
return _M
