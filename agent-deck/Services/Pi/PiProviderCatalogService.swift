import Foundation

/// Enumerates every provider PI can connect to — not just the ones currently in
/// the model catalog. `pi --list-models` only surfaces providers with free or
/// already-authorized models, so the Add Provider picker reads the full list
/// from pi-ai's `getProviders()` instead.
struct PiProviderCatalogService: Sendable {
    private let commandRunner: CommandRunning
    private let piResolver: PiExecutableResolver

    init(commandRunner: CommandRunning = CommandRunner(), piResolver: PiExecutableResolver = PiExecutableResolver()) {
        self.commandRunner = commandRunner
        self.piResolver = piResolver
    }

    func loadConnectableProviders() async -> [String] {
        let piPath = piResolver.resolve()?.path ?? "pi"

        // Walk up from the real pi binary to pi-ai's models.js (same technique
        // as PiModelDiscoveryService), then call getProviders().
        let script = #"""
        import { existsSync, realpathSync } from 'node:fs';
        import { dirname, resolve } from 'node:path';

        const candidates = [];
        const piPath = process.env.AGENT_DECK_PI_PATH;
        if (piPath && existsSync(piPath)) {
          try {
            const realPath = realpathSync(piPath);
            let dir = dirname(realPath);
            for (let i = 0; i < 10; i++) {
              const earendil = resolve(dir, 'node_modules/@earendil-works/pi-ai/dist/models.js');
              const mario    = resolve(dir, 'node_modules/@mariozechner/pi-ai/dist/models.js');
              if (existsSync(earendil)) { candidates.push(earendil); break; }
              if (existsSync(mario))    { candidates.push(mario);    break; }
              const parent = dirname(dir);
              if (parent === dir) break;
              dir = parent;
            }
          } catch {}
        }
        candidates.push(
          '/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/models.js',
          '/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai/dist/models.js',
        );

        const modulePath = candidates.find((p) => existsSync(p));
        if (!modulePath) throw new Error('Could not locate pi-ai models.js');
        const models = await import(modulePath);
        const providers = typeof models.getProviders === 'function' ? models.getProviders() : [];
        process.stdout.write(JSON.stringify(providers));
        """#

        do {
            let result = try await commandRunner.run(
                "node",
                arguments: ["--input-type=module", "--eval", script],
                currentDirectoryURL: nil,
                timeout: 8,
                environment: ["AGENT_DECK_PI_PATH": piPath]
            )
            guard result.exitCode == 0,
                  let data = result.stdout.data(using: .utf8),
                  let providers = try JSONSerialization.jsonObject(with: data) as? [String]
            else {
                return []
            }
            return providers
        } catch {
            return []
        }
    }
}
