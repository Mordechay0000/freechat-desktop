// FreeChat overlay file. New file — do not edit upstream sources for this.
//
// Header-only on purpose: adding a .cpp to Telegram Desktop means editing
// Telegram/CMakeLists.txt's source list, which is one more upstream file to
// merge on every bump. Everything here is small and inline, so the build system
// never learns this file exists.
#pragma once

#include "owpengram/owpengram_servers.h"

#include <optional>
#include <vector>

namespace FreeChatBuiltin {

// --- Build-time configuration -----------------------------------------------
// Rewritten by scripts/apply-overlay.sh from desktop/branding/brand.env.

// The node, as host:port.
//
// A hostname is CORRECT here, unlike on Android. The desktop transport connects
// through QTcpSocket::connectToHost(const QString&, int)
// (SourceFiles/mtproto/details/mtproto_tcp_socket.cpp:54), and Qt resolves names
// itself. Android's native transport uses inet_pton, which does not, which is why
// that build compiles in an IP and resolves the domain in Java first. Verified in
// both codebases rather than assumed — an earlier guess about exactly this cost a
// broken build.
inline constexpr auto kServerHost = "freechat.forum-dev.com";
inline constexpr auto kServerPort = 8080;
inline constexpr auto kServerName = "FreeChat";
inline constexpr auto kServerDescription = "Private node";
inline constexpr auto kServerDc = 2;
inline constexpr auto kServerId = "freechat";

// Skip the server picker and connect straight to the node.
inline constexpr auto kAutoJoin = true;

// Keep the upstream fork's own entries in the picker. Both false: a private
// network has no use for either, and leaving them selectable is how a client
// ends up holding a live session on someone else's server.
inline constexpr auto kIncludeTelegram = false;
inline constexpr auto kIncludeUpstreamPublic = false;

// The node's RSA public key, PKCS#1 PEM. Public by design: every client needs it
// to talk to the server. Empty disables the built-in entry, which leaves the
// picker as the only way in — correct, rather than a dead end.
inline constexpr auto kServerRsaPublicKey = "";

// --- Implementation ---------------------------------------------------------

[[nodiscard]] inline Owpengram::Server BuiltinServer() {
	auto result = Owpengram::Server();
	result.id = QString::fromUtf8(kServerId);
	result.name = QString::fromUtf8(kServerName);
	result.description = QString::fromUtf8(kServerDescription);
	result.host = QString::fromUtf8(kServerHost);
	result.port = kServerPort;
	result.rsaPublicKey = QString::fromUtf8(kServerRsaPublicKey);
	// Built-in: not editable or removable like a user-added server.
	result.isOfficial = true;
	// Not Telegram's network. multiDc must stay false or the client tries to
	// reach data centres 1 and 3-5 that do not exist on a single-machine backend.
	result.isTelegram = false;
	result.multiDc = false;
	result.mainDcId = kServerDc;
	return result;
}

// The built-in entry, or nullopt when this build has no usable one.
[[nodiscard]] inline std::optional<Owpengram::Server> MaybeServer() {
	auto server = BuiltinServer();
	if (server.rsaPublicKey.isEmpty() || !server.valid()) {
		return std::nullopt;
	}
	return server;
}

// The server to join without asking, or nullopt to show the picker.
[[nodiscard]] inline std::optional<Owpengram::Server> AutoJoinServer() {
	return kAutoJoin ? MaybeServer() : std::nullopt;
}

// Rewrites the list Owpengram::ListServers() just built: this node first, the
// upstream fork's entries dropped unless this build opted back in, and every
// server the user added themselves kept untouched.
[[nodiscard]] inline std::vector<Owpengram::Server> AdjustServerList(
		std::vector<Owpengram::Server> upstream) {
	auto result = std::vector<Owpengram::Server>();
	const auto own = MaybeServer();
	if (own) {
		result.push_back(*own);
	}
	for (auto &server : upstream) {
		if (server.id.isEmpty()) {
			continue;
		}
		if (server.id == QString::fromUtf8(Owpengram::kTelegramServerId)
			&& !kIncludeTelegram) {
			continue;
		}
		if (server.id == QString::fromUtf8(Owpengram::kOfficialServerId)
			&& !kIncludeUpstreamPublic) {
			continue;
		}
		// A user-added server sharing our id would shadow the built-in entry in
		// FindServer(); keep ours.
		if (own && server.id == own->id) {
			continue;
		}
		result.push_back(std::move(server));
	}
	// Never hand back an empty list: with no key compiled in and both upstream
	// entries dropped there would be nothing to sign in to and no way to add
	// anything. Falling back is worse than intended but still usable, and the
	// build that causes it is a brand.env mistake to fix.
	if (result.empty()) {
		return upstream;
	}
	return result;
}

} // namespace FreeChatBuiltin
