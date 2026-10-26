# RPM spec for Naxlo Two (Linux).
#
# Consumed by packaging/linux/build_packages.sh, which drops a prepared staging
# tree into SOURCES/tree.tar.gz and expands it under the buildroot — so this spec
# owns *metadata and scriptlets*, not compilation. Keeping it that way means the
# same staging tree produces the .deb and the .rpm, and the two cannot drift into
# installing different file sets.
#
# Placeholders substituted by the builder: @VERSION@ @ARCH@ @DESC@

Name:           naxlo-two
Version:        0.2.8
Release:        1%{?dist}
Summary:        @DESC@
License:        MIT
URL:            https://github.com/Manixpcshot/Naxlo-Two
Source0:        tree.tar.gz
BuildArch:      @ARCH@

Requires:       gtk3
Recommends:       nss

%description
Proxy client that configures and supervises Xray-core or sing-box as a child
process. Local SOCKS5/HTTP inbounds, optional system-proxy takeover, per-profile
routing and DNS, and a ranker that scores servers on latency, jitter,
reliability and throughput instead of ping alone. No telemetry — profiles,
samples and logs stay in the user's app-support directory.

%prep
%setup -q -c -T
tar xzf %{SOURCE0} -C .

%install
mkdir -p %{buildroot}
cp -a ./usr ./opt %{buildroot}/ 2>/dev/null || true
rm -rf %{buildroot}/DEBIAN

%post
# TUN needs CAP_NET_ADMIN/CAP_NET_RAW on the engine binary. Best-effort: a system
# without setcap (or an rpm run by a non-root user) must still install.
if command -v setcap >/dev/null 2>&1; then
  for bin in /opt/naxlo-two/sing-box /opt/naxlo-two/xray; do
    [ -x "$bin" ] && setcap cap_net_admin,cap_net_raw=eip "$bin" 2>/dev/null || :
  done
fi
update-desktop-database >/dev/null 2>&1 || :

%preun
# Never leave a 127.0.0.1 proxy behind because a package was removed mid-session.
# Two paths, in order of preference: ask the app to do it (it knows the ports the
# user configured), and if the binary is already gone, fall back to clearing the
# GNOME keys only when they still point at our default ports — a user who set a
# corporate proxy by hand must not have it wiped by our uninstaller.
if [ "$1" = "0" ]; then
  if [ -x /opt/naxlo-two/naxlo_two ]; then
    /opt/naxlo-two/naxlo_two --disable-system-proxy >/dev/null 2>&1 || :
  elif command -v gsettings >/dev/null 2>&1; then
    host="$(gsettings get org.gnome.system.proxy.socks host 2>/dev/null | tr -d "'")"
    port="$(gsettings get org.gnome.system.proxy.socks port 2>/dev/null)"
    case "$host:$port" in
      127.0.0.1:20151|127.0.0.1:20152|localhost:20151|localhost:20152)
        gsettings set org.gnome.system.proxy mode 'none' || :
        ;;
    esac
  fi
fi

%files
%defattr(-,root,root,-)
/opt/naxlo-two
/usr/bin/naxlo-two
/usr/share/applications/naxlo-two.desktop
/usr/share/doc/naxlo-two
%license /usr/share/doc/naxlo-two/LICENSE

%changelog
* Sat Oct 25 2026 Naxlo <packaging@naxlo.dev> - @VERSION@-1
- First packaged build: two ranking modes, Xray + sing-box, per-profile routing.
