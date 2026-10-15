#include "Overview.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/pass/ClearPassElement.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>

// Workspace capture is an internal compositor operation. Keep this access
// extension isolated to this translation unit and the pinned Hyprland version.
#define protected public
#include <hyprland/src/render/Renderer.hpp>
#undef protected

namespace Hypraxis {
namespace {

using Clock = std::chrono::steady_clock;
using Framebuffer = SP<Render::IFramebuffer>;
using Texture = SP<Render::ITexture>;
constexpr double TRANSITION_SECONDS = 0.21;
constexpr std::size_t MAX_CARDS = 9;
constexpr const char* PASS_NAME = "HypraxisOverview";

float progress(Clock::time_point start) {
    return std::clamp(std::chrono::duration<float>(Clock::now() - start).count() / static_cast<float>(TRANSITION_SECONDS), 0.F, 1.F);
}

float ease(float t) {
    return 1.F - std::pow(1.F - t, 3.F);
}

struct Geometry {
    CBox box;
    float alpha = 0.F;
    float focus = 0.F;
};

Geometry interpolate(const Geometry& a, const Geometry& b, float t) {
    return {{a.box.x + (b.box.x - a.box.x) * t,
             a.box.y + (b.box.y - a.box.y) * t,
             a.box.width + (b.box.width - a.box.width) * t,
             a.box.height + (b.box.height - a.box.height) * t},
            a.alpha + (b.alpha - a.alpha) * t,
            a.focus + (b.focus - a.focus) * t};
}

CBox inset(CBox box, double amount) {
    box.x += amount;
    box.y += amount;
    box.width = std::max(1.0, box.width - amount * 2.0);
    box.height = std::max(1.0, box.height - amount * 2.0);
    return box;
}

// Children own their textures for the duration of the frame, so rapid input and
// cache eviction cannot invalidate a pass already queued by the compositor.
class OverviewPass final : public IPassElement {
  public:
    OverviewPass(std::vector<UP<IPassElement>> children, Vector2D logicalSize, bool liveBlur)
        : m_children(std::move(children)), m_logicalSize(logicalSize), m_liveBlur(liveBlur) {}

    std::vector<UP<IPassElement>> draw() override { return std::move(m_children); }
    bool needsLiveBlur() override { return m_liveBlur; }
    bool needsPrecomputeBlur() override { return false; }
    const char* passName() override { return PASS_NAME; }
    ePassElementType type() override { return EK_CUSTOM; }
    bool undiscardable() override { return true; }
    bool disableSimplification() override { return true; }
    std::optional<CBox> boundingBox() override { return CBox{{0, 0}, m_logicalSize}; }
    CRegion opaqueRegion() override { return {}; }

  private:
    std::vector<UP<IPassElement>> m_children;
    Vector2D m_logicalSize;
    bool m_liveBlur;
};

void addRect(std::vector<UP<IPassElement>>& elements, const CBox& box, CHyprColor color, int round = 0, bool blur = false, float blurAlpha = 1.F) {
    CRectPassElement::SRectData data;
    data.box = box;
    data.color = color;
    data.round = round;
    data.blur = blur;
    data.blurA = blurAlpha;
    elements.emplace_back(makeUnique<CRectPassElement>(data));
}

void addTexture(std::vector<UP<IPassElement>>& elements, const Texture& texture, const CBox& box, float alpha, int round = 0) {
    if (!texture || alpha <= 0.F)
        return;
    CTexPassElement::SRenderData data;
    data.tex = texture;
    data.box = box;
    data.a = alpha;
    data.round = round;
    elements.emplace_back(makeUnique<CTexPassElement>(std::move(data)));
}

struct WorkspaceState {
    PHLWORKSPACE workspace;
    bool visible;
    bool forceRendering;
    float alpha;
    Vector2D offset;
};

struct WindowState {
    PHLWINDOW window;
    Vector2D position;
    Vector2D size;
    float moveToAlpha;
    float moveFromAlpha;
};

// Use the mutable value accessor instead of warping animated variables. A warp
// can fire completion callbacks and disconnect animations; restoring value()
// leaves the original goals, callbacks, spring state and animation clock intact.
class CaptureState {
  public:
    CaptureState(PHLMONITOR monitor, const PHLWORKSPACE& target)
        : m_monitor(monitor), m_active(monitor->m_activeWorkspace), m_special(monitor->m_activeSpecialWorkspace),
          m_dim(monitor->m_specialDim->value()), m_blur(monitor->m_specialBlur->value()),
          m_feedback(g_pHyprRenderer->m_bBlockSurfaceFeedback), m_snapshot(g_pHyprRenderer->m_bRenderingSnapshot),
          m_renderData(g_pHyprRenderer->m_renderData), m_mode(g_pHyprRenderer->m_renderMode) {
        for (const auto& workspace : State::workspaceState()->workspacesCopy()) {
            if (!workspace || !workspace->m_alpha || !workspace->m_renderOffset)
                continue;
            m_workspaces.push_back({workspace, workspace->m_visible, workspace->m_forceRendering, workspace->m_alpha->value(), workspace->m_renderOffset->value()});
            workspace->m_visible = workspace == target;
            workspace->m_forceRendering = workspace == target;
            workspace->m_alpha->value() = workspace == target ? 1.F : 0.F;
            workspace->m_renderOffset->value() = {};
        }
        for (const auto& window : Desktop::windowState()->windows()) {
            if (!window || !window->m_isMapped || window->isHidden() || window->m_workspace != target)
                continue;
            m_windows.push_back({window, window->positionAnimation()->value(), window->sizeAnimation()->value(),
                                 window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_TO_WORKSPACE)->value(),
                                 window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE)->value()});
            window->positionAnimation()->value() = window->positionAnimation()->goal();
            window->sizeAnimation()->value() = window->sizeAnimation()->goal();
            window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_TO_WORKSPACE)->value() = 1.F;
            window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE)->value() = 1.F;
        }
        // This pointer is consulted by rendering only. No workspace dispatcher,
        // focus change, layout recalculation, IPC event or client configure runs.
        m_monitor->m_activeWorkspace = target;
        m_monitor->m_activeSpecialWorkspace.reset();
        m_monitor->m_specialDim->value() = 0.F;
        m_monitor->m_specialBlur->value() = 0.F;
        g_pHyprRenderer->m_bBlockSurfaceFeedback = true;
        g_pHyprRenderer->m_bRenderingSnapshot = true;
    }

    ~CaptureState() {
        for (const auto& state : m_windows) {
            state.window->positionAnimation()->value() = state.position;
            state.window->sizeAnimation()->value() = state.size;
            state.window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_TO_WORKSPACE)->value() = state.moveToAlpha;
            state.window->alpha(Desktop::View::WINDOW_ALPHA_MOVE_FROM_WORKSPACE)->value() = state.moveFromAlpha;
        }
        for (const auto& state : m_workspaces) {
            state.workspace->m_visible = state.visible;
            state.workspace->m_forceRendering = state.forceRendering;
            state.workspace->m_alpha->value() = state.alpha;
            state.workspace->m_renderOffset->value() = state.offset;
        }
        m_monitor->m_activeWorkspace = m_active;
        m_monitor->m_activeSpecialWorkspace = m_special;
        m_monitor->m_specialDim->value() = m_dim;
        m_monitor->m_specialBlur->value() = m_blur;
        g_pHyprRenderer->m_bBlockSurfaceFeedback = m_feedback;
        g_pHyprRenderer->m_bRenderingSnapshot = m_snapshot;
        g_pHyprRenderer->m_renderData = m_renderData;
        g_pHyprRenderer->m_renderMode = m_mode;
    }

  private:
    PHLMONITOR m_monitor;
    PHLWORKSPACE m_active, m_special;
    float m_dim, m_blur;
    bool m_feedback, m_snapshot;
    Render::SRenderData m_renderData;
    Render::eRenderMode m_mode;
    std::vector<WorkspaceState> m_workspaces;
    std::vector<WindowState> m_windows;
};

PHLWORKSPACE findWorkspace(WORKSPACEID id) {
    for (const auto& workspace : State::workspaceState()->workspacesCopy()) {
        if (workspace && workspace->m_id == id && !workspace->inert())
            return workspace;
    }
    return {};
}

Framebuffer captureWorkspace(PHLMONITOR monitor, const PHLWORKSPACE& workspace) {
    // A foreign monitor's workspace has different geometry. Do not temporarily
    // move its windows or its monitor; the UI displays an explicit placeholder.
    if (workspace && workspace->m_monitor != monitor)
        return {};
    auto framebuffer = g_pHyprRenderer->createFB("hypraxis-preview");
    const auto format = monitor->useFP16() ? DRM_FORMAT_ABGR16161616F : DRM_FORMAT_ARGB8888;
    if (!framebuffer->alloc(static_cast<int>(monitor->m_pixelSize.x), static_cast<int>(monitor->m_pixelSize.y), format))
        return {};
    framebuffer->setImageDescription(monitor->workBufferImageDescription());
    CaptureState state(monitor, workspace);
    CRegion damage(CBox{{0, 0}, monitor->m_transformedSize});
    if (!g_pHyprRenderer->beginRender(monitor, damage, Render::RENDER_MODE_FULL_FAKE, nullptr, framebuffer, false))
        return {};
    bool ended = false;
    Render::CScopeGuard finish([&] {
        if (!ended)
            g_pHyprRenderer->endRender();
    });
    g_pHyprRenderer->m_renderData.blockScreenShader = true;
    CClearPassElement::SClearData clear;
    clear.color = CHyprColor(0.025, 0.035, 0.06, 1.0);
    g_pHyprRenderer->addPassElement(makeUnique<CClearPassElement>(clear));
    g_pHyprRenderer->renderWorkspace(monitor, workspace, Time::steadyNow(), CBox{{0, 0}, monitor->m_pixelSize});
    g_pHyprRenderer->endRender();
    ended = true;
    // The compositor writes output-oriented pixels in its final fake-render
    // blit. Undo that output transform when the image becomes a card texture.
    framebuffer->getTexture()->m_transform = Math::wlTransformToHyprutils(Math::invertTransform(monitor->m_transform));
    // Client buffer references remain with the renderer until the real frame
    // following beforeRender submits its normal explicit or implicit fence.
    return framebuffer;
}

// A small, local Gaussian blur makes the background independent of the user's
// decoration blur preferences. It never changes compositor configuration and
// never reads screen pixels back to the CPU.
Framebuffer blurBackground(PHLMONITOR monitor, const Framebuffer& source) {
    if (!source || !source->getTexture())
        return {};
    const char* vertex = R"glsl(#version 300 es
layout(location = 0) in vec2 position;
out vec2 uv;
void main() { uv = position * 0.5 + 0.5; gl_Position = vec4(position, 0.0, 1.0); }
)glsl";
    const char* fragment = R"glsl(#version 300 es
precision highp float;
in vec2 uv;
uniform sampler2D image;
uniform vec2 stepSize;
out vec4 color;
void main() {
    color = texture(image, uv) * 0.227027;
    color += (texture(image, uv + stepSize) + texture(image, uv - stepSize)) * 0.1945946;
    color += (texture(image, uv + stepSize * 2.0) + texture(image, uv - stepSize * 2.0)) * 0.1216216;
    color += (texture(image, uv + stepSize * 3.0) + texture(image, uv - stepSize * 3.0)) * 0.054054;
    color += (texture(image, uv + stepSize * 4.0) + texture(image, uv - stepSize * 4.0)) * 0.016216;
}
)glsl";
    std::array<GLuint, 2> shaders{glCreateShader(GL_VERTEX_SHADER), glCreateShader(GL_FRAGMENT_SHADER)};
    GLuint program = glCreateProgram();
    Render::CScopeGuard deleteShaders([&] {
        glDeleteProgram(program);
        for (auto shader : shaders)
            glDeleteShader(shader);
    });
    const std::array<const char*, 2> sources{vertex, fragment};
    for (std::size_t i = 0; i < shaders.size(); ++i) {
        glShaderSource(shaders[i], 1, &sources[i], nullptr);
        glCompileShader(shaders[i]);
        GLint compiled = GL_FALSE;
        glGetShaderiv(shaders[i], GL_COMPILE_STATUS, &compiled);
        if (!compiled)
            return {};
        glAttachShader(program, shaders[i]);
    }
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked)
        return {};

    const int width = std::max(64, std::min(640, static_cast<int>(monitor->m_pixelSize.x / 3)));
    const int height = std::max(64, static_cast<int>(width * monitor->m_pixelSize.y / monitor->m_pixelSize.x));
    auto horizontal = g_pHyprRenderer->createFB("hypraxis-blur-horizontal");
    auto blurred = g_pHyprRenderer->createFB("hypraxis-background");
    if (!horizontal->alloc(width, height, source->m_drmFormat) || !blurred->alloc(width, height, source->m_drmFormat))
        return {};
    horizontal->setImageDescription(source->imageDescription());
    blurred->setImageDescription(source->imageDescription());
    blurred->getTexture()->m_transform = source->getTexture()->m_transform;

    GLint previousProgram = 0, previousFramebuffer = 0, previousArray = 0, previousBuffer = 0, previousActiveTexture = 0, previousTexture = 0;
    std::array<GLint, 4> previousViewport{};
    glGetIntegerv(GL_CURRENT_PROGRAM, &previousProgram);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previousFramebuffer);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &previousArray);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &previousBuffer);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &previousActiveTexture);
    glGetIntegerv(GL_VIEWPORT, previousViewport.data());
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &previousTexture);
    const GLboolean blend = glIsEnabled(GL_BLEND), scissor = glIsEnabled(GL_SCISSOR_TEST), stencil = glIsEnabled(GL_STENCIL_TEST);
    GLuint array = 0, buffer = 0;
    glGenVertexArrays(1, &array);
    glGenBuffers(1, &buffer);
    Render::CScopeGuard restoreGL([&] {
        glBindVertexArray(previousArray);
        glBindBuffer(GL_ARRAY_BUFFER, previousBuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, previousFramebuffer);
        glViewport(previousViewport[0], previousViewport[1], previousViewport[2], previousViewport[3]);
        glUseProgram(previousProgram);
        glBindTexture(GL_TEXTURE_2D, previousTexture);
        glActiveTexture(previousActiveTexture);
        if (blend) glEnable(GL_BLEND); else glDisable(GL_BLEND);
        if (scissor) glEnable(GL_SCISSOR_TEST); else glDisable(GL_SCISSOR_TEST);
        if (stencil) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
        glDeleteBuffers(1, &buffer);
        glDeleteVertexArrays(1, &array);
    });
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_STENCIL_TEST);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "image"), 0);
    glBindVertexArray(array);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    constexpr std::array<GLfloat, 8> vertices{-1.F, -1.F, 1.F, -1.F, -1.F, 1.F, 1.F, 1.F};
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glViewport(0, 0, width, height);
    horizontal->bind();
    glBindTexture(GL_TEXTURE_2D, source->getTexture()->m_texID);
    glUniform2f(glGetUniformLocation(program, "stepSize"), 2.F / width, 0.F);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    blurred->bind();
    glBindTexture(GL_TEXTURE_2D, horizontal->getTexture()->m_texID);
    glUniform2f(glGetUniformLocation(program, "stepSize"), 0.F, 2.F / height);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    return blurred;
}

} // namespace

class OverviewRenderer::Impl {
  public:
    struct Card {
        WORKSPACEID id;
        Framebuffer framebuffer;
        Texture label;
        Geometry from, target;
        Clock::time_point transition;
        bool wanted = true;
        bool captured = false;
        bool foreign = false;
        int slot = 0;
        Geometry geometry() const { return interpolate(from, target, ease(progress(transition))); }
    };

    PHLMONITORREF monitor;
    Selection selected;
    WORKSPACEID origin = 0;
    bool opened = false;
    bool closing = false;
    bool capturing = false;
    bool committed = false;
    bool prepareBackground = false;
    Clock::time_point openedAt, closedAt;
    float closeOpacity = 1.F;
    std::vector<Card> cards;
    Framebuffer background;
    Texture heading, footer, empty, foreign;
    std::array<Texture, 5> directionLabels;

    float opacity() const {
        if (!closing)
            return ease(progress(openedAt));
        const float t = progress(closedAt);
        return closeOpacity * (1.F - t * t * (3.F - 2.F * t));
    }

    void damage() const {
        if (const auto mon = monitor.lock()) {
            g_pHyprRenderer->damageMonitor(mon);
            mon->scheduleFrame();
        }
    }

    std::array<Geometry, 5> layout() const {
        const auto mon = monitor.lock();
        const auto size = mon->m_transformedSize;
        const double width = size.x * 0.38, height = size.y * 0.38;
        const double sideWidth = size.x * 0.23, sideHeight = size.y * 0.23;
        const double x = size.x * 0.5, y = size.y * 0.49;
        const double dx = (width + sideWidth) * 0.5 + size.x * 0.025;
        const double dy = (height + sideHeight) * 0.5 + size.y * 0.025;
        return {Geometry{{x - width / 2, y - height / 2, width, height}, 1.F, 1.F},
                Geometry{{x - dx - sideWidth / 2, y - sideHeight / 2, sideWidth, sideHeight}, 0.82F, 0.F},
                Geometry{{x + dx - sideWidth / 2, y - sideHeight / 2, sideWidth, sideHeight}, 0.82F, 0.F},
                Geometry{{x - sideWidth / 2, y - dy - sideHeight / 2, sideWidth, sideHeight}, 0.82F, 0.F},
                Geometry{{x - sideWidth / 2, y + dy - sideHeight / 2, sideWidth, sideHeight}, 0.82F, 0.F}};
    }

    void setSelection(const Selection& next, bool initial) {
        const auto boxes = layout();
        const auto now = Clock::now();
        const auto mon = monitor.lock();
        Vector2D shift;
        if (!initial) {
            if (next.id == selected.left) shift = {mon->m_transformedSize.x * 0.33, 0.0};
            else if (next.id == selected.right) shift = {-mon->m_transformedSize.x * 0.33, 0.0};
            else if (next.id == selected.up) shift = {0.0, mon->m_transformedSize.y * 0.33};
            else if (next.id == selected.down) shift = {0.0, -mon->m_transformedSize.y * 0.33};
        }
        for (auto& card : cards) {
            card.from = card.geometry();
            card.target = card.from;
            card.target.box.translate(shift);
            card.target.alpha = 0.F;
            card.target.focus = 0.F;
            card.wanted = false;
            card.transition = now;
        }
        const std::array<WORKSPACEID, 5> ids{next.id, next.left, next.right, next.up, next.down};
        for (std::size_t slot = 0; slot < ids.size(); ++slot) {
            if (ids[slot] <= 0)
                continue;
            auto it = std::find_if(cards.begin(), cards.end(), [&](const auto& card) { return card.id == ids[slot]; });
            if (it == cards.end()) {
                Geometry from = boxes[slot];
                from.box.translate(-shift);
                from.alpha = 0.F;
                if (initial && slot == 0)
                    from = {CBox{{0, 0}, mon->m_transformedSize}, 1.F, 1.F};
                else if (initial) {
                    from.box.x = (from.box.x + boxes[0].box.x) * 0.5;
                    from.box.y = (from.box.y + boxes[0].box.y) * 0.5;
                }
                cards.push_back({.id = ids[slot], .framebuffer = {}, .label = {}, .from = from, .target = boxes[slot], .transition = now,
                                 .wanted = true, .captured = false, .foreign = false, .slot = static_cast<int>(slot)});
            } else {
                it->target = boxes[slot];
                it->wanted = true;
                it->slot = static_cast<int>(slot);
            }
        }
        // Evict outgoing previews first. At most nine workspace images remain,
        // even when key repeat outruns the animation and render loop.
        while (cards.size() > MAX_CARDS) {
            const auto victim = std::find_if(cards.begin(), cards.end(), [](const auto& card) { return !card.wanted; });
            if (victim == cards.end())
                break;
            cards.erase(victim);
        }
        selected = next;
    }

    void prepareText() {
        const auto mon = monitor.lock();
        const int pt = std::max(10, static_cast<int>(14 * mon->m_scale));
        if (!heading) {
            heading = g_pHyprRenderer->renderText("HYPRAXIS", CHyprColor(0.8, 0.87, 0.98, 1.0), pt, false, "sans-serif", 0, 600);
            footer = g_pHyprRenderer->renderText("H  J  K  L   Navigate     Enter   Select     Esc   Cancel", CHyprColor(0.72, 0.78, 0.88, 1.0), pt, false, "sans-serif");
            empty = g_pHyprRenderer->renderText("Empty workspace", CHyprColor(0.55, 0.63, 0.75, 1.0), pt, false, "sans-serif");
            foreign = g_pHyprRenderer->renderText("On another monitor", CHyprColor(0.55, 0.63, 0.75, 1.0), pt, false, "sans-serif");
            constexpr std::array<const char*, 5> keys{"Enter", "H", "L", "K", "J"};
            for (std::size_t i = 0; i < keys.size(); ++i)
                directionLabels[i] = g_pHyprRenderer->renderText(keys[i], CHyprColor(0.9, 0.94, 1.0, 1.0), std::max(10, pt - 1), false, "sans-serif", 0, 600);
        }
        const WORKSPACEID columns = selected.down > selected.id ? selected.down - selected.id :
            selected.up > 0 ? selected.id - selected.up : 10;
        for (auto& card : cards) {
            if (card.label)
                continue;
            const auto x = (card.id - 1) % columns + 1;
            const auto y = (card.id - 1) / columns + 1;
            card.label = g_pHyprRenderer->renderText("Project " + std::to_string(x) + "  /  Row " + std::to_string(y),
                                                    CHyprColor(0.88, 0.92, 1.0, 1.0), pt, false, "sans-serif", 0, 500);
        }
    }

    std::vector<UP<IPassElement>> elements() const {
        const auto mon = monitor.lock();
        const auto size = mon->m_transformedSize;
        const float opening = opacity();
        const double scale = mon->m_scale;
        std::vector<UP<IPassElement>> result;
        if (background)
            addTexture(result, background->getTexture(), CBox{{0, 0}, size}, opening);
        addRect(result, CBox{{0, 0}, size}, CHyprColor(0.017, 0.025, 0.045, 0.65 * opening), 0, !background, opening);
        const auto addCentered = [&](const Texture& texture, double y, float alpha) {
            if (texture)
                addTexture(result, texture, CBox{(size.x - texture->m_size.x) / 2.0, y, texture->m_size.x, texture->m_size.y}, alpha);
        };
        addCentered(heading, size.y * 0.017, opening * 0.85F);
        addCentered(footer, size.y * 0.955, opening);

        std::vector<const Card*> ordered;
        for (const auto& card : cards)
            ordered.push_back(&card);
        std::stable_sort(ordered.begin(), ordered.end(), [](const Card* a, const Card* b) { return a->geometry().focus < b->geometry().focus; });
        for (const auto* card : ordered) {
            Geometry geometry = card->geometry();
            float alpha = geometry.alpha;
            // The initial center starts as the full desktop itself; surrounding
            // cards fade in as it shrinks into the selection cross.
            if (closing) {
                const auto amount = ease(progress(closedAt));
                if (committed && card->wanted && card->id == selected.id) {
                    const Geometry full{CBox{{0, 0}, size}, 1.F, 1.F};
                    geometry = interpolate(geometry, full, amount);
                }
                alpha *= opening;
            } else if (card->id != origin || progress(openedAt) >= 1.F) {
                alpha *= opening;
            }
            if (alpha < 0.002F)
                continue;
            auto box = geometry.box;
            const int round = static_cast<int>(16 * scale);
            const double border = (1.5 + geometry.focus) * scale;
            // Layered translucent silhouettes give restrained depth without
            // modifying Hyprland's shadow settings or depending on its theme.
            for (int layer = 3; layer > 0; --layer) {
                auto shadow = box.copy().expand(layer * 3.0 * scale).translate({0.0, 4 * scale});
                addRect(result, shadow, CHyprColor(0, 0, 0, (0.035 + 0.025 * geometry.focus) * alpha), round + layer * 3 * scale);
            }
            addRect(result, box, CHyprColor(0.35 + geometry.focus * 0.23, 0.48 + geometry.focus * 0.24, 0.64 + geometry.focus * 0.28, alpha), round);
            auto content = inset(box, border);
            addRect(result, content, CHyprColor(0.04, 0.06, 0.10, alpha), std::max(0, round - static_cast<int>(border)));
            if (card->framebuffer)
                addTexture(result, card->framebuffer->getTexture(), content, alpha, std::max(0, round - static_cast<int>(border)));
            else {
                // Empty cells remain useful destinations; no workspace is
                // created until the user confirms the selected coordinate.
                const Texture placeholder = card->foreign ? foreign : empty;
                if (placeholder) {
                    const double factor = std::min(1.0, (content.width - 24 * scale) / placeholder->m_size.x);
                    const auto textSize = placeholder->m_size * factor;
                    addTexture(result, placeholder, CBox{content.x + (content.width - textSize.x) / 2, content.y + (content.height - textSize.y) / 2, textSize.x, textSize.y}, alpha * 0.9F);
                }
                const double lineWidth = std::max(12.0 * scale, content.width * 0.075);
                addRect(result, CBox{content.x + (content.width - lineWidth) / 2, content.y + content.height * 0.37, lineWidth, 2 * scale}, CHyprColor(0.38, 0.60, 0.83, alpha * 0.55), scale);
            }
            const double captionHeight = std::min(38 * scale, content.height * 0.28);
            CBox caption{content.x, content.y + content.height - captionHeight, content.width, captionHeight};
            addRect(result, caption, CHyprColor(0.015, 0.023, 0.04, alpha * 0.91));
            if (card->label) {
                const double factor = std::min(1.0, (caption.width - 80 * scale) / card->label->m_size.x);
                const auto textSize = card->label->m_size * std::max(0.2, factor);
                addTexture(result, card->label, CBox{caption.x + 12 * scale, caption.y + (caption.height - textSize.y) / 2, textSize.x, textSize.y}, alpha);
            }
            if (card->wanted && directionLabels[card->slot]) {
                const auto key = directionLabels[card->slot];
                const double keyWidth = key->m_size.x + 14 * scale;
                const double keyHeight = std::min(captionHeight - 8 * scale, key->m_size.y + 6 * scale);
                CBox badge{caption.x + caption.width - keyWidth - 9 * scale, caption.y + (captionHeight - keyHeight) / 2, keyWidth, keyHeight};
                addRect(result, badge, CHyprColor(0.2, 0.32, 0.47, alpha * (0.42 + 0.22 * geometry.focus)), 5 * scale);
                addTexture(result, key, CBox{badge.x + (badge.width - key->m_size.x) / 2, badge.y + (badge.height - key->m_size.y) / 2, key->m_size.x, key->m_size.y}, alpha * 0.85F);
            }
        }
        return result;
    }
};

OverviewRenderer::OverviewRenderer() : m_impl(std::make_unique<Impl>()) {}
OverviewRenderer::~OverviewRenderer() { reset(); }

bool OverviewRenderer::open(PHLMONITOR monitor, const Selection& selection) {
    if (!monitor || selection.id <= 0 || !g_pHyprRenderer || !Render::GL::g_pHyprOpenGL || g_pHyprRenderer->type() != Render::IHyprRenderer::RT_GL)
        return false;
    reset();
    m_impl->monitor = monitor;
    m_impl->selected = selection;
    m_impl->origin = selection.id;
    m_impl->opened = true;
    m_impl->closing = false;
    m_impl->committed = false;
    m_impl->openedAt = Clock::now();
    m_impl->prepareBackground = true;
    m_impl->setSelection(selection, true);
    m_impl->damage();
    return true;
}

bool OverviewRenderer::update(const Selection& selection) {
    if (!m_impl->opened || m_impl->closing || !m_impl->monitor || selection.id <= 0)
        return false;
    if (selection.id == m_impl->selected.id)
        return true;
    Render::GL::g_pHyprOpenGL->makeEGLCurrent();
    m_impl->setSelection(selection, false);
    m_impl->damage();
    return true;
}

void OverviewRenderer::close(bool commit) {
    if (!m_impl->opened || m_impl->closing)
        return;
    m_impl->closeOpacity = m_impl->opacity();
    m_impl->closedAt = Clock::now();
    m_impl->closing = true;
    m_impl->committed = commit;
    m_impl->damage();
}

void OverviewRenderer::reset() {
    if (!m_impl)
        return;
    if (g_pHyprRenderer) {
        g_pHyprRenderer->m_renderPass.removeAllOfType(PASS_NAME);
        if (Render::GL::g_pHyprOpenGL)
            Render::GL::g_pHyprOpenGL->makeEGLCurrent();
    }
    const auto oldMonitor = m_impl->monitor.lock();
    *m_impl = Impl{};
    if (oldMonitor && g_pHyprRenderer) {
        g_pHyprRenderer->damageMonitor(oldMonitor);
        oldMonitor->scheduleFrame();
    }
}

void OverviewRenderer::beforeRender(PHLMONITOR monitor) {
    if (!m_impl->opened || m_impl->capturing || monitor != m_impl->monitor)
        return;
    Render::GL::g_pHyprOpenGL->makeEGLCurrent();
    m_impl->capturing = true;
    Render::CScopeGuard finish([&] { m_impl->capturing = false; });
    m_impl->prepareText();
    // The current desktop is captured first for the opening transition and
    // frozen blurred backdrop. Capture only visible candidates after movement.
    for (auto& card : m_impl->cards) {
        if (!card.wanted || card.captured)
            continue;
        const auto workspace = findWorkspace(card.id);
        card.foreign = workspace && workspace->m_monitor != monitor;
        if (workspace && !card.foreign)
            card.framebuffer = captureWorkspace(monitor, workspace);
        card.captured = true;
        if (m_impl->prepareBackground && card.id == m_impl->origin && card.framebuffer) {
            m_impl->background = blurBackground(monitor, card.framebuffer);
            m_impl->prepareBackground = false;
        }
    }
}

void OverviewRenderer::render(eRenderStage stage) {
    if (stage != RENDER_LAST_MOMENT || !m_impl->opened || m_impl->capturing || !m_impl->monitor ||
        g_pHyprRenderer->m_renderData.pMonitor != m_impl->monitor)
        return;
    const auto mon = m_impl->monitor.lock();
    g_pHyprRenderer->addPassElement(makeUnique<OverviewPass>(m_impl->elements(), mon->m_size, !m_impl->background));
}

void OverviewRenderer::tick() {
    if (!m_impl->opened)
        return;
    if (!m_impl->monitor || (m_impl->closing && progress(m_impl->closedAt) >= 1.F)) {
        reset();
        return;
    }
    Render::GL::g_pHyprOpenGL->makeEGLCurrent();
    std::erase_if(m_impl->cards, [](const auto& card) { return !card.wanted && progress(card.transition) >= 1.F; });
    // An open overview needs continuous damage for its animation. The parent
    // timer controls cadence; snapshots themselves stay frozen until reopened.
    m_impl->damage();
}

bool OverviewRenderer::active() const { return m_impl->opened; }
bool OverviewRenderer::animating() const {
    if (!m_impl->opened)
        return false;
    if (m_impl->closing || progress(m_impl->openedAt) < 1.F)
        return true;
    return std::any_of(m_impl->cards.begin(), m_impl->cards.end(), [](const auto& card) {
        return (card.wanted && !card.captured) || progress(card.transition) < 1.F;
    });
}
bool OverviewRenderer::closing() const { return m_impl->closing; }
bool OverviewRenderer::capturing() const { return m_impl->capturing; }
PHLMONITOR OverviewRenderer::monitor() const { return m_impl->monitor.lock(); }
WORKSPACEID OverviewRenderer::origin() const { return m_impl->origin; }
Selection OverviewRenderer::selection() const { return m_impl->selected; }
std::size_t OverviewRenderer::previewCount() const { return m_impl->cards.size(); }

} // namespace Hypraxis
