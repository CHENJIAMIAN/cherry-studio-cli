# Third-party notices

Cherry Studio CLI does not bundle CLIProxyAPI, its binaries, configuration, or
credentials.

The optional CLIProxyAPI integration targets
[router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI),
which is released under the MIT License. The reproducibility patch in
patches/cliproxyapi-api-key-env.patch is intended for that project and is
limited to allowing an OpenAI-compatible provider key to be resolved from a
runtime environment variable.
