include $(TOPDIR)/rules.mk

PKG_NAME:=rustdesk-discoveryd
PKG_VERSION:=1.0
PKG_RELEASE:=2

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/rustdesk-discoveryd
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=RustDesk
  TITLE:=RustDesk LAN peer discovery daemon
  URL:=https://github.com/tizbac/rustdeskdiscover
  DEPENDS:=+libstdcpp
endef

define Package/rustdesk-discoveryd/description
  RustDesk LAN peer discovery daemon for OpenWrt.
  Discovers RustDesk clients on the local network using the same
  UDP broadcast protocol used by the RustDesk desktop client
  (port 21119) and records them in /tmp/rustdesk_peers.json.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CXX) $(TARGET_CFLAGS) -Os -Wall \
		-o $(PKG_BUILD_DIR)/rustdesk-discoveryd \
		$(PKG_BUILD_DIR)/rustdesk-discoveryd.cpp
endef

define Package/rustdesk-discoveryd/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/rustdesk-discoveryd $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/rustdesk-discoveryd.init $(1)/etc/init.d/rustdesk-discoveryd
endef

$(eval $(call BuildPackage,rustdesk-discoveryd))
