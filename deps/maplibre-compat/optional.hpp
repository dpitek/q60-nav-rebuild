// optional.hpp — compatibility shim for mapbox-base / maplibre-gl-native
// The mbgl/util/optional.hpp in older maplibre builds expects this file to
// provide std::experimental::optional via mapbox-base's header-only optional.
// We're building with C++17, so std::optional is available — alias it.
#pragma once

#include <optional>

namespace std {
namespace experimental {

template <typename T>
using optional = std::optional<T>;

using nullopt_t = std::nullopt_t;
static constexpr std::nullopt_t nullopt = std::nullopt;

template <typename T>
constexpr optional<std::decay_t<T>> make_optional(T &&v) {
    return std::make_optional<std::decay_t<T>>(std::forward<T>(v));
}

} // namespace experimental
} // namespace std
