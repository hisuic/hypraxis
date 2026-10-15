#include "Overview.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/config/lua/ConfigManager.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/SessionLockManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/output/Monitor.hpp>

#include <xkbcommon/xkbcommon-keysyms.h>
#include <chrono>
#include <cmath>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
HANDLE pluginHandle = nullptr;
constexpr WORKSPACEID MAX_ID = 9007199254740991;

int failure(lua_State* L, const std::string& message) {
    lua_pushnil(L);
    lua_pushlstring(L, message.data(), message.size());
    return 2;
}

int success(lua_State* L) {
    lua_pushboolean(L, true);
    return 1;
}

WORKSPACEID integerField(lua_State* L, const char* name, bool allowZero = false) {
    lua_getfield(L, 1, name);
    const bool numeric = lua_type(L, -1) == LUA_TNUMBER;
    const auto value = lua_tonumber(L, -1);
    lua_pop(L, 1);
    if (!numeric || !std::isfinite(value) || value != std::floor(value)
        || value < (allowZero ? 0 : 1) || value > MAX_ID)
        throw std::invalid_argument(std::string("invalid overview field: ") + name);
    return static_cast<WORKSPACEID>(value);
}

Hypraxis::Selection selectionFrom(lua_State* L) {
    if (!lua_istable(L, 1)) throw std::invalid_argument("overview state must be a table");
    Hypraxis::Selection next;
    next.id = integerField(L, "id");
    const auto x = integerField(L, "x");
    next.y = integerField(L, "y");
    if (x > 10 || (next.id - 1) % 10 + 1 != x || (next.id - 1) / 10 + 1 != next.y)
        throw std::invalid_argument("inconsistent overview coordinates");
    next.x = static_cast<int>(x);
    next.left = integerField(L, "left", true);
    next.right = integerField(L, "right", true);
    next.up = integerField(L, "up", true);
    next.down = integerField(L, "down", true);
    return next;
}

class Runtime {
  public:
    Hypraxis::OverviewRenderer renderer;
    lua_State* callbackState = nullptr;
    int callbackRef = LUA_NOREF;
    std::vector<CHyprSignalListener> listeners;
    SP<CEventLoopTimer> timer;
    std::unordered_set<std::uint32_t> swallowedKeys;
    std::unordered_set<std::uint32_t> swallowedButtons;
    std::uint32_t repeatCode = 0;
    std::string repeatKey;
    Clock::time_point repeatAt;

    Runtime() {
        auto& events = Event::bus()->m_events;
        listeners.push_back(events.input.keyboard.key.listen([this](IKeyboard::SKeyEvent event, Event::SCallbackInfo& info) {
            const bool released = event.state == WL_KEYBOARD_KEY_STATE_RELEASED;
            if (released) {
                if (swallowedKeys.erase(event.keycode)) info.cancelled = true;
                if (repeatCode == event.keycode) repeatKey.clear();
                return;
            }
            if (!renderer.active()) return;
            info.cancelled = true;
            swallowedKeys.insert(event.keycode);
            if (renderer.closing()) return;
            const auto keyboard = g_pSeatManager->m_keyboard.lock();
            if (!keyboard || !keyboard->m_xkbSymState) return;
            const auto symbol = xkb_keysym_to_lower(xkb_state_key_get_one_sym(keyboard->m_xkbSymState, event.keycode + 8));
            std::string key;
            switch (symbol) {
                case XKB_KEY_h: case XKB_KEY_Left: key = "h"; break;
                case XKB_KEY_j: case XKB_KEY_Down: key = "j"; break;
                case XKB_KEY_k: case XKB_KEY_Up: key = "k"; break;
                case XKB_KEY_l: case XKB_KEY_Right: key = "l"; break;
                case XKB_KEY_Return: case XKB_KEY_KP_Enter: key = "enter"; break;
                case XKB_KEY_Escape: key = "escape"; break;
                case XKB_KEY_space:
                    if (keyboard->getModifiers() & HL_MODIFIER_META) key = "escape";
                    break;
                default: break;
            }
            if (key.empty()) return;
            if (key.size() == 1) {
                repeatCode = event.keycode;
                repeatKey = key;
                repeatAt = Clock::now() + std::chrono::milliseconds(300);
            } else repeatKey.clear();
            invoke(key);
        }));
        listeners.push_back(events.input.mouse.move.listen([this](Vector2D, Event::SCallbackInfo& info) {
            if (renderer.active()) info.cancelled = true;
        }));
        listeners.push_back(events.input.mouse.button.listen([this](IPointer::SButtonEvent event, Event::SCallbackInfo& info) {
            if (event.state == WL_POINTER_BUTTON_STATE_RELEASED) {
                if (swallowedButtons.erase(event.button)) info.cancelled = true;
            } else if (renderer.active()) {
                swallowedButtons.insert(event.button);
                info.cancelled = true;
            }
        }));
        listeners.push_back(events.input.mouse.axis.listen([this](IPointer::SAxisEvent, Event::SCallbackInfo& info) {
            if (renderer.active()) info.cancelled = true;
        }));
        listeners.push_back(events.input.touch.down.listen([this](ITouch::SDownEvent, Event::SCallbackInfo& info) {
            if (renderer.active()) { info.cancelled = true; cancel(); }
        }));
        listeners.push_back(events.workspace.active.listen([this](PHLWORKSPACE) { cancelExternal(); }));
        listeners.push_back(events.workspace.specialActive.listen([this](PHLWORKSPACE, PHLMONITOR) { cancelExternal(); }));
        listeners.push_back(events.monitor.focused.listen([this](PHLMONITOR) { cancelExternal(); }));
        listeners.push_back(events.monitor.layoutChanged.listen([this] { cancel(); }));
        listeners.push_back(events.monitor.preRemoved.listen([this](PHLMONITOR monitor) {
            if (renderer.monitor() == monitor) cancel();
        }));
        listeners.push_back(events.config.preReload.listen([this] {
            // Lua references must be released before Hyprland destroys the VM.
            cancel(false);
        }));
        if (g_pSessionLockManager)
            listeners.push_back(g_pSessionLockManager->m_events.lock.listen([this] { cancel(); }));
        listeners.push_back(events.render.preChecks.listen([this](PHLMONITOR) {
            if (!renderer.active()) return;
            if (g_pSessionLockManager && g_pSessionLockManager->isSessionLocked()) { cancel(); return; }
            g_pHyprRenderer->m_directScanoutBlocked = true;
        }));
        listeners.push_back(events.render.pre.listen([this](PHLMONITOR monitor) {
            guarded([&] { renderer.beforeRender(monitor); });
        }));
        listeners.push_back(events.render.stage.listen([this](eRenderStage stage) {
            guarded([&] { renderer.render(stage); });
        }));
        timer = makeShared<CEventLoopTimer>(std::nullopt, [this](SP<CEventLoopTimer> self, void*) {
            guarded([&] {
                if (renderer.active() && !renderer.closing() && !repeatKey.empty() && Clock::now() >= repeatAt) {
                    invoke(repeatKey);
                    repeatAt = Clock::now() + std::chrono::milliseconds(65);
                }
                renderer.tick();
                if (!renderer.active()) clearCallback();
            });
            if (renderer.active() && (renderer.animating() || !repeatKey.empty()))
                self->updateTimeout(std::chrono::milliseconds(16));
        }, nullptr);
        g_pEventLoopManager->addTimer(timer);
    }

    ~Runtime() {
        cancel(false);
        listeners.clear();
        timer->cancel();
        g_pEventLoopManager->removeTimer(timer);
    }

    void clearCallback() {
        repeatKey.clear();
        if (callbackState && callbackRef != LUA_NOREF)
            luaL_unref(callbackState, LUA_REGISTRYINDEX, callbackRef);
        callbackState = nullptr;
        callbackRef = LUA_NOREF;
    }

    void invoke(const std::string& key) {
        if (!callbackState || callbackRef == LUA_NOREF) return;
        auto* L = callbackState;
        const int stack = lua_gettop(L);
        lua_rawgeti(L, LUA_REGISTRYINDEX, callbackRef);
        lua_pushlstring(L, key.data(), key.size());
        auto* manager = Config::Lua::CConfigManager::fromLuaState(L);
        const int result = manager ? manager->guardedPCall(1, 0, 0, 50, "Hypraxis overview input") : lua_pcall(L, 1, 0, 0);
        if (result != LUA_OK) {
            lua_settop(L, stack);
            cancel(false);
            HyprlandAPI::addNotification(pluginHandle, "Hypraxis overview closed after a Lua callback error", CHyprColor(0xf0b48aff), 4000);
            return;
        }
        lua_settop(L, stack);
    }

    void cancel(bool notify = true) {
        const bool wasOpen = renderer.active();
        renderer.reset();
        repeatKey.clear();
        if (timer) timer->updateTimeout(std::nullopt);
        if (notify && wasOpen) invoke("cancel");
        clearCallback();
    }

    void cancelExternal() {
        if (renderer.active() && !renderer.closing() && !renderer.capturing()) cancel();
    }

    template <typename Fn> void guarded(Fn&& fn) {
        try { fn(); }
        catch (const std::exception&) {
            cancel(false);
            HyprlandAPI::addNotification(pluginHandle, "Hypraxis overview closed after a rendering error", CHyprColor(0xf0b48aff), 4000);
        }
    }
};

std::unique_ptr<Runtime> runtime;

int openOverview(lua_State* L) {
    try {
        const auto selection = selectionFrom(L);
        if (!lua_isfunction(L, 2)) return failure(L, "overview requires an input callback");
        if (runtime->renderer.active()) return failure(L, "overview is already open or closing");
        if (g_pSessionLockManager && g_pSessionLockManager->isSessionLocked()) return failure(L, "session is locked");
        if (g_pSeatManager->m_seatGrab) return failure(L, "another interface owns input");
        const auto monitor = Desktop::focusState()->monitor();
        if (!monitor || !monitor->m_activeWorkspace || monitor->m_activeSpecialWorkspace)
            return failure(L, "no active regular workspace");
        if (monitor->m_activeWorkspace->m_id != selection.id)
            return failure(L, "workspace changed while opening the overview");
        if (!runtime->renderer.open(monitor, selection)) return failure(L, "could not initialize overview rendering");
        runtime->clearCallback();
        lua_pushvalue(L, 2);
        runtime->callbackRef = luaL_ref(L, LUA_REGISTRYINDEX);
        runtime->callbackState = L;
        runtime->timer->updateTimeout(std::chrono::milliseconds(1));
        return success(L);
    } catch (const std::exception& error) {
        runtime->cancel(false);
        return failure(L, error.what());
    }
}

int updateOverview(lua_State* L) {
    try {
        const auto selection = selectionFrom(L);
        if (!runtime->renderer.update(selection)) return failure(L, "overview is unavailable or closing");
        runtime->timer->updateTimeout(std::chrono::milliseconds(1));
        return success(L);
    } catch (const std::exception& error) { return failure(L, error.what()); }
}

int closeOverview(lua_State* L) {
    if (!lua_isboolean(L, 1)) return failure(L, "overview close requires a commit flag");
    try {
        runtime->renderer.close(lua_toboolean(L, 1));
        runtime->repeatKey.clear();
        if (runtime->renderer.active()) runtime->timer->updateTimeout(std::chrono::milliseconds(1));
        return success(L);
    } catch (const std::exception& error) { return failure(L, error.what()); }
}

int isOpen(lua_State* L) {
    lua_pushboolean(L, runtime->renderer.active());
    return 1;
}

int status(lua_State* L) {
    lua_newtable(L);
    const auto selected = runtime->renderer.selection();
    auto boolean = [&](const char* name, bool value) { lua_pushboolean(L, value); lua_setfield(L, -2, name); };
    auto integer = [&](const char* name, lua_Integer value) { lua_pushinteger(L, value); lua_setfield(L, -2, name); };
    boolean("active", runtime->renderer.active());
    boolean("closing", runtime->renderer.closing());
    boolean("capturing", runtime->renderer.capturing());
    boolean("animating", runtime->renderer.animating());
    integer("origin", runtime->renderer.origin());
    integer("id", selected.id);
    integer("x", selected.x);
    integer("y", selected.y);
    integer("previews", runtime->renderer.previewCount());
    return 1;
}

}

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    pluginHandle = handle;
    const auto version = HyprlandAPI::getHyprlandVersion(handle);
    if (version.hash != GIT_COMMIT_HASH || std::string(__hyprland_api_get_hash()) != __hyprland_api_get_client_hash())
        throw std::runtime_error("Hypraxis overview requires matching Hyprland 0.56.2 headers and dependency ABI");
    runtime = std::make_unique<Runtime>();
    for (const auto& [name, function] : std::vector<std::pair<std::string, PLUGIN_LUA_FN>>{
        {"open", openOverview}, {"update", updateOverview}, {"close", closeOverview}, {"is_open", isOpen}, {"status", status}}) {
        if (!HyprlandAPI::addLuaFunction(handle, "hypraxis_overview", name, function)) {
            runtime.reset();
            throw std::runtime_error("could not register Hypraxis overview Lua API");
        }
    }
    return {"hypraxis_overview", "Animated two-dimensional workspace overview", "Hypraxis contributors", "0.2.0"};
}

APICALL EXPORT void PLUGIN_EXIT() { runtime.reset(); }
