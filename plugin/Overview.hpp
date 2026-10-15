#pragma once

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/desktop/DesktopTypes.hpp>

#include <cstddef>
#include <cstdint>
#include <memory>

namespace Hypraxis {

struct Selection {
    WORKSPACEID id = 0;
    int x = 1;
    std::int64_t y = 1;
    WORKSPACEID left = 0;
    WORKSPACEID right = 0;
    WORKSPACEID up = 0;
    WORKSPACEID down = 0;
};

// The renderer owns only transient GPU previews; Lua owns workspace navigation.
class OverviewRenderer {
  public:
    OverviewRenderer();
    ~OverviewRenderer();
    OverviewRenderer(const OverviewRenderer&) = delete;
    OverviewRenderer& operator=(const OverviewRenderer&) = delete;

    bool open(PHLMONITOR monitor, const Selection& selection);
    bool update(const Selection& selection);
    void close(bool commit);
    void reset();

    void beforeRender(PHLMONITOR monitor);
    void render(eRenderStage stage);
    void tick();

    bool active() const;
    bool closing() const;
    bool capturing() const;
    PHLMONITOR monitor() const;
    WORKSPACEID origin() const;
    Selection selection() const;
    std::size_t previewCount() const;

  private:
    class Impl;
    std::unique_ptr<Impl> m_impl;
};

}
