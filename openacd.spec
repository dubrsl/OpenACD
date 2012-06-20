Name: openacd
Version: 2.0
Summary: OpenACD Call Center
Release: alt1.git.54357e2
Group: System/Servers
License: CPAL
Url: http://github.com/OpenACD/OpenACD/wiki
Source: %name-%version.tar

BuildRequires: rpm-build-erlang rebar erlang-devel erlang-otp-devel mochiweb-devel erlang-protobuffs erlang-errd erlang-gen_smtp erlang-gen_leader_revival erlang-gen_server_mock erlang-meck erlang-iconv erlang-erlnetstr

%description
OpenACD is a skills-based, Call Center software based on FreeSWITCH and built in erlang.

%prep
%setup
sed -i ''6,19d'' rebar.config
sed -i ''79,81d'' Makefile
ln -s %_erllibdir deps
sed -i '/^install/s/compile//' Makefile

%build
rebar -v compile

%install
make install DESTDIR=$RPM_BUILD_ROOT PREFIX=%prefix

mv -f %buildroot/usr/var %buildroot/var
mv -f %buildroot/usr/etc %buildroot/etc
mkdir -p %buildroot%_erllibdir
mv -f %buildroot%_libdir/openacd/lib/openacd-2.0 %buildroot%_erllibdir/

exit 1

%files
%_libdir/openacd
%_erllibdir/*
/var/lib/openacd
/var/log/openacd
/etc/openacd
/usr/bin/*

%changelog
* Wed Jun 20 2012 Slava Dubrovskiy <dubrsl@altlinux.org> 2.0-alt1.git.54357e2
- Build for ALT
