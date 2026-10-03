# Cross Build Toolchain Libraries

This resource tree is the stable in-app home for compiler adapters, support data, SDK metadata, templates and embedded runtimes.

A catalogue item is always registered with Cross Build. "Embedded Engine" means it can execute in-process. "Bundled Support Library" means Cross Build ships integration/resources but execution may still require a backend. "Backend Adapter" means the UI, project detection, command planning and diagnostics integration ship in the app while compilation requires Jailbreak Local or Remote/SSH execution.

Native binary/framework payloads can be added to the matching directory without changing workspace configuration.
