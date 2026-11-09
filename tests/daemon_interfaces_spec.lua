-- The transport and the root object (spec §19.8, §19.9, §19.20; step 5g.1):
-- the transport range, `welcome.objects`, the envelope, `loomworks.Root/1`
-- (describe, schema, subscribe, unsubscribe, objects_changed, retiring) over
-- the real socket and the loopback, and the dispatch table.

_G.LOOMWORKS_CLI_NO_AUTORUN = true
local uv = vim.uv or vim.loop
local protocol = require("loomworks.daemon.protocol")
local server_mod = require("loomworks.daemon.server")
local client = require("loomworks.daemon.client")
local version = require("loomworks.daemon.version")
local interfaces = require("loomworks.daemon.interfaces")
local documents = require("loomworks.proto.documents")
local envelope = require("loomworks.proto.envelope")
local auth = require("loomworks.daemon.auth")
local trust = require("loomworks.trust")
local H = require("tests.daemon_helpers")

client.TIMEOUT_MS = 30000

local ROOT, RIF = "/", "loomworks.Root"

--- A test interface: one method, a signal with an initial state, another
--- without, and subscription args (`subscribe_args`).
local function test_doc(extra)
    local doc = {
        interface = "lwtest.Echo", version = 1, status = "draft",
        methods = {
            echo = {
                params = { type = "object", required = { "text" }, properties = { text = { type = "string" } } },
                result = { type = "object", required = { "text" }, properties = { text = { type = "string" } } },
            },
        },
        signals = {
            ticked = {
                args = { type = "object", required = { "n" }, properties = { n = { type = "integer" } } },
                initial = true,
            },
            tocked = {
                args = { type = "object", required = { "n" }, properties = { n = { type = "integer" } } },
            },
        },
        subscribe_args = { type = "object", additionalProperties = false, properties = { only = { type = "integer" } } },
    }
    for k, v in pairs(extra or {}) do doc[k] = v end
    return doc
end

local function echo_impl(over)
    local impl = {
        doc = test_doc(),
        methods = { echo = function(_, args) return { text = args.text } end },
        initial = function() return { n = 0 } end,
    }
    for k, v in pairs(over or {}) do impl[k] = v end
    return impl
end

--- Collects the broadcasts a session receives.
local function inbox()
    local box = { msgs = {} }
    function box.on_message(m) box.msgs[#box.msgs + 1] = m end
    function box.signals(name)
        local out = {}
        for _, m in ipairs(box.msgs) do
            if m.kind == "signal" and (not name or m.name == name) then out[#out + 1] = m end
        end
        return out
    end
    return box
end

local function read_doc(rel)
    local f = assert(io.open(documents.dir() .. "/" .. rel, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

describe("transport range (§19.8, §19.9)", function()
    it("is 1 with protocol_min 1, and negotiates the highest common version", function()
        assert.equals(1, version.PROTOCOL)
        assert.equals(1, version.PROTOCOL_MIN)
        assert.equals(1, version.negotiate(1, 1))
        assert.equals(1, version.negotiate(1))         -- no minimum stated: [1, 1]
        assert.equals(1, version.negotiate(3, 1))      -- a later client that still speaks 1
        assert.is_nil(version.negotiate(3, 2))
        assert.is_nil(version.negotiate(nil))
    end)

    it("shares no version with the pre-0.2.0 transport numbers (up to 11)", function()
        -- Those pre-releases stated [10, 11] or no minimum (10, and earlier).
        assert.is_nil(version.negotiate(11, 10))
        assert.is_nil(version.negotiate(10))
        assert.is_nil(version.negotiate(11))
        local me = version.schemas()
        local ok, what = version.observer_compatible({ protocol = 11, protocol_min = 10, schemas = me })
        assert.is_false(ok)
        assert.equals("protocol", what)
    end)

    it("lets an editor observe a daemon whose range overlaps, not one whose range does not", function()
        local me = version.schemas()
        assert.is_true((version.observer_compatible({ protocol = 1, schemas = me })))
        assert.is_true((version.observer_compatible({ protocol = 2, protocol_min = 1, schemas = me })))
        local ok, what = version.observer_compatible({ protocol = 3, protocol_min = 2, schemas = me })
        assert.is_false(ok)
        assert.equals("protocol", what)
    end)

    it("the envelope treats an unknown error code as internal unless the interface declares it", function()
        assert.equals("invalid_args", envelope.code_of({ code = "invalid_args" }))
        assert.equals("internal", envelope.code_of({ code = "brand_new" }))
        assert.equals("brand_new", envelope.code_of({ code = "brand_new" }, { brand_new = {} }))
        assert.equals("internal", envelope.code_of("a string"))
    end)
end)

describe("root object over the socket (§19.20)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { exit = function() end, tick_ms = 100, auth_timeout_ms = 30000 })
        assert(srv:start())
    end)
    after_each(function()
        if not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("announces the range in the challenge and the objects in welcome", function()
        local conn = assert(client.session(srv.address))
        assert.equals(1, conn.challenge.protocol)
        assert.equals(1, conn.challenge.protocol_min)
        local objs = conn.welcome.objects
        assert.equals(1, #objs)
        assert.equals("/", objs[1].path)
        assert.equals("core", objs[1].owner)
        assert.equals(RIF, objs[1].interfaces[1].name)
        assert.same({ 1 }, objs[1].interfaces[1].versions)
        assert.is_nil(objs[1].interfaces[1].schema_digest)
        -- The header's session fields are untouched beside it.
        assert.equals(srv.pid, conn.welcome.header.pid)
        local sc
        for c in pairs(srv.conns) do sc = c end
        assert.equals(1, sc.transport)
        conn:close()
    end)

    it("describe: binary, transport range, generation, objects with digests, root methods", function()
        local conn = assert(client.session(srv.address))
        local d, err = client.call_sync(conn, ROOT, RIF, 1, "describe", {})
        assert.is_nil(err)
        assert.equals(srv.identity, d.binary.lw_version)
        assert.equals("lua", d.binary.impl)
        assert.is_true(d.binary.dev) -- a source tree
        assert.same({ min = 1, max = 1 }, d.transport)
        assert.equals(srv.generation, d.session_generation)
        assert.same({ "describe", "schema", "subscribe", "unsubscribe" }, d.root_methods)
        assert.equals("subscription", d.delivery)
        local info = d.objects[1].interfaces[1]
        assert.equals(vim.fn.sha256(read_doc("interfaces/loomworks/Root.1.json")), info.schema_digest["1"])
        -- The result is valid against the Root schema.
        local set = documents.set()
        assert.is_true(set:validate("interfaces/loomworks/Root.1.json", "/methods/describe/result", d))
        conn:close()
    end)

    it("schema: serves Root/1 and the types-only Common/1; unknown name and version are typed errors", function()
        local conn = assert(client.session(srv.address))
        local doc = assert(client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = 1 }))
        assert.same(vim.json.decode(read_doc("interfaces/loomworks/Root.1.json")), doc)
        local common = assert(client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = "loomworks.Common", v = 1 }))
        assert.equals("loomworks.Common", common.interface)
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = "loomworks.Nope", v = 1 })
        assert.equals("unknown_interface", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = 2 })
        assert.equals("unsupported_version", e.code)
        assert.same({ 1 }, e.data.versions)
        conn:close()
    end)

    it("routing errors: unknown object / interface / version / method, invalid args, malformed call", function()
        local conn = assert(client.session(srv.address))
        local _, e = client.call_sync(conn, "/nowhere", RIF, 1, "describe", {})
        assert.equals("unknown_object", e.code)
        _, e = client.call_sync(conn, ROOT, "loomworks.Build", 1, "build", {})
        assert.equals("unknown_interface", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 3, "describe", {})
        assert.equals("unsupported_version", e.code)
        assert.same({ 1 }, e.data.versions)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "explode", {})
        assert.equals("unknown_method", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { v = 1 })
        assert.equals("invalid_args", e.code)
        assert.truthy(e.message:find("missing required property 'iface'", 1, true), e.message)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = "1" })
        assert.equals("invalid_args", e.code)
        assert.truthy(e.message:find("/v", 1, true), e.message)
        local reply, rerr = client.request(conn, { kind = "call", object = ROOT, iface = RIF, method = "describe" })
        assert.is_nil(reply)
        assert.equals("invalid_args", rerr.code)
        conn:close()
    end)

    it("subscribe: initial state, stamped signals with seq, filters, unsubscribe, dropped on close", function()
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        local box = inbox()
        local conn = assert(client.session(srv.address, { on_message = box.on_message }))
        local other = assert(client.session(srv.address))
        local r = assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "ticked" }, args = { only = 2 } }))
        -- An opaque string carrying the session generation (§19.20).
        assert.is_string(r.sub_id)
        assert.truthy(r.sub_id:find(tostring(srv.generation), 1, true), r.sub_id)
        assert.equals(0, r.seq)
        assert.same({ n = 0 }, r.initial)
        local echo = assert(client.call_sync(other, "/echo", "lwtest.Echo", 1, "echo", { text = "hi" }))
        assert.equals("hi", echo.text)
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 1 }))
        assert.equals(0, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 2 },
            function(a) return a.only == 3 end))
        assert.is_true(vim.wait(5000, function() return #box.signals("ticked") == 1 end, 10))
        local s = box.signals("ticked")[1]
        assert.equals(r.sub_id, s.sub_id)
        assert.equals("/echo", s.object)
        assert.equals(1, s.v)
        assert.equals(r.seq + 1, s.seq)
        -- Signals this connection is never sent use up no seq: emitted to
        -- nobody, refused by the filter, a signal it did not subscribe to,
        -- the other connection's.
        assert.equals(0, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 9 },
            function(a) return a.only == 7 end))
        local r2 = assert(client.call_sync(other, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "tocked" } }))
        assert.equals(0, r2.seq)
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "tocked", { n = 1 }))
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "tocked", { n = 2 }))
        assert(client.call_sync(other, ROOT, RIF, 1, "unsubscribe", { sub_id = r2.sub_id }))
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 10 }))
        assert.is_true(vim.wait(5000, function() return #box.signals("ticked") == 2 end, 10))
        assert.equals(s.seq + 1, box.signals("ticked")[2].seq)
        -- A later subscription of the same connection starts from the last
        -- seq it was sent on that object.
        local r3 = assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "tocked" } }))
        assert.equals(s.seq + 1, r3.seq)
        assert(client.call_sync(conn, ROOT, RIF, 1, "unsubscribe", { sub_id = r3.sub_id }))
        -- Subscription args are checked against subscribe_args.
        local _, ae = client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, args = { only = "x" } })
        assert.equals("invalid_args", ae.code)
        assert.truthy(ae.message:find("/args/only", 1, true), ae.message)
        -- An unknown signal name is invalid_args.
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/echo", iface = "lwtest.Echo", v = 1, signals = { "nope" } })
        assert.equals("invalid_args", e.code)
        _, e = client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 2 })
        assert.equals("unsupported_version", e.code)
        -- Another connection cannot drop it; its owner can.
        assert(client.call_sync(other, ROOT, RIF, 1, "unsubscribe", { sub_id = r.sub_id }))
        assert.equals(1, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 3 }))
        local u = assert(client.call_sync(conn, ROOT, RIF, 1, "unsubscribe", { sub_id = r.sub_id }))
        assert.same({}, u)
        assert.equals(0, srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 4 }))
        -- Closing drops a connection's subscriptions.
        assert(client.call_sync(other, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 1 }))
        other:close()
        assert.is_true(vim.wait(5000, function() return next(srv.interfaces.subs) == nil end, 10))
        conn:close()
    end)

    it("an interface without subscribe_args refuses subscription args", function()
        local doc = test_doc()
        doc.subscribe_args = nil
        assert(srv.interfaces:mount("/plain", "core", "lwtest.Echo", 1, echo_impl({ doc = doc })))
        local conn = assert(client.session(srv.address))
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/plain", iface = "lwtest.Echo", v = 1, args = { only = 2 } })
        assert.equals("invalid_args", e.code)
        assert.truthy(e.message:find("takes no subscription args", 1, true), e.message)
        assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/plain", iface = "lwtest.Echo", v = 1 }))
        assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe",
            { object = "/plain", iface = "lwtest.Echo", v = 1, args = vim.empty_dict() }))
        conn:close()
    end)

    it("an empty result goes out as its schema types it: [] for an array, {} for an object", function()
        local doc = test_doc()
        doc.methods.list = { params = { type = "object" }, result = { type = "array", items = { type = "string" } } }
        doc.methods.nested = { params = { type = "object" }, result = { type = "object", properties = {
            items = { type = "array" }, meta = { type = "object" } } } }
        assert(srv.interfaces:mount("/lists", "core", "lwtest.Echo", 1, echo_impl({ doc = doc, methods = {
            echo = function(_, a) return { text = a.text } end,
            list = function() return {} end,
            nested = function() return { items = {}, meta = {} } end,
        } })))
        local conn = assert(client.session(srv.address))
        local l, e = client.call_sync(conn, "/lists", "lwtest.Echo", 1, "list", {})
        assert.is_nil(e)
        assert.same({}, l)
        assert.is_nil(getmetatable(l)) -- decoded from [], not {}
        local nres = assert(client.call_sync(conn, "/lists", "lwtest.Echo", 1, "nested", {}))
        assert.is_nil(getmetatable(nres.items))
        assert.equals(vim._empty_dict_mt, getmetatable(nres.meta))
        conn:close()
    end)

    it("describe lists versions in numeric order", function()
        for _, v in ipairs({ 10, 9 }) do
            local doc = test_doc({ version = v })
            assert(srv.interfaces:mount("/multi", "core", "lwtest.Echo", v, echo_impl({ doc = doc })))
        end
        local conn = assert(client.session(srv.address))
        local d = assert(client.call_sync(conn, ROOT, RIF, 1, "describe", {}))
        local found
        for _, o in ipairs(d.objects) do if o.path == "/multi" then found = o end end
        assert.same({ 9, 10 }, found.interfaces[1].versions)
        local _, e = client.call_sync(conn, "/multi", "lwtest.Echo", 3, "echo", { text = "x" })
        assert.same({ 9, 10 }, e.data.versions)
        conn:close()
    end)

    it("stop drops every connection's subscriptions", function()
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        local conn = assert(client.session(srv.address))
        assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 1 }))
        assert.is_not_nil(next(srv.interfaces.subs))
        srv:stop("test", 0)
        assert.is_nil(next(srv.interfaces.subs))
        conn:close()
    end)

    it("the client records the agreed transport and refuses an interface call without one at once", function()
        local conn = assert(client.session(srv.address))
        assert.equals(1, conn.transport)
        conn.transport = nil -- as against a daemon whose range shares no version
        local _, e = client.call_sync(conn, ROOT, RIF, 1, "describe", {})
        assert.equals(client.ERR_TRANSPORT, e.code)
        assert.truthy(e.message:find("no protocol version was agreed", 1, true), e.message)
        conn:close()
    end)

    it("objects_changed reaches every connection on mount and unmount; welcome lists the object", function()
        local box = inbox()
        local conn = assert(client.session(srv.address, { on_message = box.on_message }))
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        assert.is_true(vim.wait(5000, function() return #box.signals("objects_changed") == 1 end, 10))
        local s = box.signals("objects_changed")[1]
        assert.equals("/", s.object)
        assert.equals(RIF, s.iface)
        assert.same({ "/echo" }, s.args.added)
        local late = assert(client.session(srv.address))
        assert.equals(2, #late.welcome.objects)
        assert.equals("/echo", late.welcome.objects[2].path)
        srv.interfaces:unmount("/echo")
        assert.is_true(vim.wait(5000, function() return #box.signals("objects_changed") == 2 end, 10))
        assert.same({ "/echo" }, box.signals("objects_changed")[2].args.removed)
        late:close()
        conn:close()
    end)

    it("refuses an interface whose methods and handlers disagree", function()
        local ok, err = srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl({ methods = {} }))
        assert.is_nil(ok)
        assert.truthy(err:find("no handler for method echo", 1, true))
        ok, err = srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl({
            methods = { echo = function() end, extra = function() end } }))
        assert.is_nil(ok)
        assert.truthy(err:find("handler extra has no method", 1, true))
        assert.is_nil(srv.interfaces.objects["/echo"])
    end)

    it("same_build interfaces need the daemon's lw_version", function()
        assert(srv.interfaces:mount("/internal", "core", "lwtest.Echo", 1, echo_impl({ same_build = true })))
        local conn = assert(client.session(srv.address))
        assert(client.call_sync(conn, "/internal", "lwtest.Echo", 1, "echo", { text = "x" }))
        for c in pairs(srv.conns) do c.peer.lw_version = "0.0.1" end
        local _, e = client.call_sync(conn, "/internal", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.equals("same_build_required", e.code)
        conn:close()
    end)

    it("a development build fails a result that does not match its schema", function()
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl({
            methods = { echo = function() return { text = 42 } end } })))
        local conn = assert(client.session(srv.address))
        local _, e = client.call_sync(conn, "/echo", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.equals("internal", e.code)
        assert.truthy(e.message:find("does not match its schema", 1, true), e.message)
        -- A handler error is internal, never a crash.
        assert(srv.interfaces:mount("/boom", "core", "lwtest.Echo", 1, echo_impl({
            methods = { echo = function() error("boom") end } })))
        _, e = client.call_sync(conn, "/boom", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.equals("internal", e.code)
        assert(client.request(conn, { kind = "ping" }))
        conn:close()
    end)

    it("a mutating method's reply that does not match its schema is logged and sent, never an error", function()
        -- The handler may have started what the reply reports (an accepted
        -- task): an error would let the client run it a second time.
        local logged = {}
        srv.opts.log = function(line) logged[#logged + 1] = line end
        local impl = echo_impl({ methods = { echo = function() return { text = 42 } end } })
        impl.doc.methods.echo.mutates = true
        srv.interfaces.validate_out = true
        assert(srv.interfaces:mount("/mut", "core", "lwtest.Echo", 1, impl))
        local conn = assert(client.session(srv.address))
        local r, e = client.call_sync(conn, "/mut", "lwtest.Echo", 1, "echo", { text = "x" })
        assert.is_nil(e)
        assert.equals(42, r.text)
        local hit = false
        for _, l in ipairs(logged) do
            if l:find("does not match its schema", 1, true) then hit = true end
        end
        assert.is_true(hit, table.concat(logged, "\n"))
        conn:close()
    end)

    it("retire sends the root's retiring signal to every connection, observers too", function()
        local box, o1 = inbox(), inbox()
        local conn = assert(client.session(srv.address, { on_message = box.on_message }))
        -- (Busy, so the daemon outlives the retirement during the test.)
        for c in pairs(srv.conns) do if c.authed then c.in_flight = { [99] = true } end end
        local obs = assert(client.session(srv.address, { on_message = o1.on_message, role = "observer" }))
        assert(client.request(conn, { kind = "retire" }))
        assert.is_true(vim.wait(5000, function() return #box.signals("retiring") == 1 end, 10))
        assert.is_true(vim.wait(5000, function() return #o1.signals("retiring") == 1 end, 10))
        -- Only the signal: no bare `retiring` frame.
        for _, m in ipairs(o1.msgs) do assert.not_equals("retiring", m.kind) end
        obs:close()
        conn:close()
    end)

    it("a pre-0.2.0 client (transport 10-11) shares no transport: only the control subset, no envelope", function()
        -- A hand-rolled handshake as those pre-releases sent it.
        local key = assert(auth.key())
        local nc = assert(auth.nonce())
        local pipe = uv.new_pipe(false)
        local dec = protocol.new_decoder(protocol.MAX_FRAME)
        local got = {}
        pipe:connect(srv.address, function(cerr)
            assert(not cerr)
            pipe:read_start(function(_, chunk)
                if not chunk then return end
                for _, m in ipairs(dec:push(chunk) or {}) do
                    got[#got + 1] = m
                    if m.kind == "challenge" then
                        pipe:write(protocol.encode({ kind = "auth",
                            client_proof = auth.client_proof(key, srv.address, nc, m.server_nonce) }))
                    end
                end
            end)
            pipe:write(protocol.encode({ kind = "hello", protocol = 11, protocol_min = 10, lw_version = "0.1.43",
                schemas = version.schemas(), client = "cli", nonce = nc }))
        end)
        local function has(kind)
            for _, m in ipairs(got) do if m.kind == kind then return m end end
        end
        assert.is_true(vim.wait(5000, function() return has("welcome") ~= nil end, 10))
        assert.equals(1, has("challenge").protocol)
        assert.equals(1, has("challenge").protocol_min)
        local sc
        for c in pairs(srv.conns) do sc = c end
        assert.is_nil(sc.transport)
        pipe:write(protocol.encode({ kind = "ping", req_id = 1 }))
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        pipe:write(protocol.encode({ kind = "build", req_id = 2 }))
        -- A call — and so a subscription — is refused without a transport.
        pipe:write(protocol.encode({ kind = "call", req_id = 3, object = "/echo", iface = "lwtest.Echo", v = 1,
            method = "echo", args = { x = 1 } }))
        pipe:write(protocol.encode({ kind = "call", req_id = 4, object = "/", iface = "loomworks.Root", v = 1,
            method = "subscribe", args = { object = "/echo", iface = "lwtest.Echo", v = 1 } }))
        assert.is_true(vim.wait(5000, function() return #got >= 6 end, 10))
        assert.equals("ok", got[3].kind)
        assert.equals(1, got[3].req_id)
        assert.equals("error", got[4].kind)
        assert.equals("table", type(got[4].error))
        assert.equals("unknown request kind: build", got[4].error.message)
        for i, req_id in ipairs({ 3, 4 }) do
            local m = got[4 + i]
            assert.equals("error", m.kind)
            assert.equals(req_id, m.req_id)
            assert.equals("no_transport", m.error.code)
            assert.equals("no protocol version agreed: the daemon speaks transport 1-1, this client 10-11",
                m.error.message)
            assert.same({ protocol = 1, protocol_min = 1 }, m.error.data)
        end
        assert.is_nil(next(srv.interfaces.subs or {}))
        for _, m in ipairs(got) do assert.not_equals("signal", m.kind) end
        pipe:close()
    end)
end)

describe("root object over the loopback (§19.1, §19.20)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { tick_ms = 100 })
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("welcomes with the objects and serves describe, schema and subscribe", function()
        local box = inbox()
        local conn = assert(client.loopback_session(srv, { on_message = box.on_message }))
        assert.equals(1, conn.challenge.protocol_min)
        assert.equals("/", conn.welcome.objects[1].path)
        local d = assert(client.call_sync(conn, ROOT, RIF, 1, "describe", {}))
        assert.same({ min = 1, max = 1 }, d.transport)
        local doc = assert(client.call_sync(conn, ROOT, RIF, 1, "schema", { iface = RIF, v = 1 }))
        assert.equals(RIF, doc.interface)
        assert(srv.interfaces:mount("/echo", "core", "lwtest.Echo", 1, echo_impl()))
        assert.is_true(vim.wait(5000, function() return #box.signals("objects_changed") == 1 end, 10))
        local r = assert(client.call_sync(conn, ROOT, RIF, 1, "subscribe", { object = "/echo", iface = "lwtest.Echo", v = 1 }))
        srv.interfaces:emit("/echo", "lwtest.Echo", 1, "ticked", { n = 5 })
        assert.is_true(vim.wait(5000, function() return #box.signals("ticked") == 1 end, 10))
        assert.equals(r.sub_id, box.signals("ticked")[1].sub_id)
        conn:close()
    end)
end)

describe("the dispatch table (§19.8)", function()
    local root, srv
    before_each(function()
        trust._set_key_path(H.tmp() .. "/trust.key")
        root = H.workspace()
        srv = server_mod.new(root, { tick_ms = 100 })
        assert(srv:start_attached({ command = "build" }))
    end)
    after_each(function()
        if srv and not srv.stopped then srv:stop("test end", 0) end
        trust._set_key_path(nil)
    end)

    it("names only the control subset and the envelope's call", function()
        local kinds = {}
        for kind, entry in pairs(server_mod.DISPATCH) do
            kinds[#kinds + 1] = kind
            assert.is_function(entry.control, kind)
        end
        table.sort(kinds)
        assert.same({ "call", "ping", "retire", "status", "stop" }, kinds)
    end)

    it("refuses the request kinds of the pre-0.2.0 transports with a structured error", function()
        local conn = assert(client.loopback_session(srv))
        for _, kind in ipairs({ "build", "test", "prepare_run", "clean", "reset", "snapshot", "query", "frobnicate" }) do
            local _, err = client.request(conn, { kind = kind, args = {} })
            assert.equals("invalid_args", err.code, kind)
            assert.equals("unknown request kind: " .. kind, err.message)
        end
        conn:close()
    end)
end)

describe("interfaces registry", function()
    it("validates outgoing results only in development builds by default", function()
        local reg = interfaces.new({ identity = "0.1.43", conns = {}, log = function() end })
        assert.is_false(reg.validate_out)
        reg = interfaces.new({ identity = "0.1.44+dev.abc", conns = {}, log = function() end })
        assert.is_true(reg.validate_out)
    end)
end)

describe("Task:_observes matches the subscription's interface version (§19.15)", function()
    local tasks_mod = require("loomworks.daemon.tasks")
    local function task_with(subs)
        return setmetatable({ id = "t1", stream = { server = { interfaces = { subs = subs } } } },
            { __index = tasks_mod.Task })
    end
    it("a connection subscribed to loomworks.Tasks/1 observes; one on another version does not", function()
        local conn = { transport = 1 }
        local function sub(v, args)
            return { s = { conn = conn, object = "/tasks", iface = "loomworks.Tasks", v = v, args = args } }
        end
        assert.is_true(task_with(sub(1)):_observes(conn))
        local t2 = task_with(sub(2))
        assert.is_false(t2:_observes(conn))
        local other = task_with(sub(1, { task_id = "t9" }))
        assert.is_false(other:_observes(conn))
        local mine = task_with(sub(1, { task_id = "t1" }))
        assert.is_true(mine:_observes(conn))
        -- One that subscribed to nothing observes nothing.
        assert.is_false(t2:_observes({ transport = 1 }))
    end)
end)
