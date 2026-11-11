/// Bridge version, injected at build time by `deploy/build_release.sh`
/// (`dart compile exe -DDIZ_VERSION=x.y.z`).
const String bridgeVersion = String.fromEnvironment('DIZ_VERSION', defaultValue: '0.1.0-dev');
