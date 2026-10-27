import { execFileSync } from 'child_process';
import fs from 'fs';
import path from 'path'
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';

const KEYCHAIN_SERVICE = 'com.jaminxx.z_pill.ohos-signing';
const LEGACY_KEYCHAIN_SERVICE = 'com.jaminxx.nikon_pill.ohos-signing';
const LOCAL_SIGNING_CONFIG = path.join(__dirname, 'signing', 'local-signing.json');
const LOCAL_BUILD_STATE_DIRS = [
    path.join(__dirname, '.hvigor'),
    path.resolve(__dirname, '..', '.hvigor'),
];

function restrictPrivatePath(target: string) {
    if (process.platform === 'win32' || !fs.existsSync(target)) {
        return;
    }

    const stat = fs.lstatSync(target);
    if (stat.isSymbolicLink()) {
        return;
    }
    if (stat.isDirectory()) {
        fs.chmodSync(target, 0o700);
        for (const entry of fs.readdirSync(target)) {
            restrictPrivatePath(path.join(target, entry));
        }
        return;
    }
    if (stat.isFile()) {
        fs.chmodSync(target, 0o600);
    }
}

if (process.platform !== 'win32') {
    process.umask(0o077);
    for (const dir of LOCAL_BUILD_STATE_DIRS) {
        restrictPrivatePath(dir);
    }
    restrictPrivatePath(LOCAL_SIGNING_CONFIG);
}

type LocalSigningConfig = {
    name?: string;
    type?: 'HarmonyOS' | 'OpenHarmony';
    material: {
        storeFile: string;
        keyAlias: string;
        profile: string;
        certpath: string;
        signAlg: 'SHA256withECDSA';
    };
};

let legacyKeychainWarningShown = false;

function readKeychainSecret(account: string): string {
  for (const service of [KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_SERVICE]) {
    try {
      const secret = execFileSync(
        '/usr/bin/security',
        ['find-generic-password', '-w', '-s', service, '-a', account],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
      ).trim();

      if (!secret) {
        continue;
      }
      if (service === LEGACY_KEYCHAIN_SERVICE && !legacyKeychainWarningShown) {
        legacyKeychainWarningShown = true;
        console.warn(
          `Using legacy Keychain service "${LEGACY_KEYCHAIN_SERVICE}". ` +
          `Move signing secrets to "${KEYCHAIN_SERVICE}" when convenient.`,
        );
      }
      return secret;
    } catch {
      // Try the legacy service before failing the build.
        }
    }
  throw new Error(
    `Missing macOS Keychain item "${account}" for services ` +
    `"${KEYCHAIN_SERVICE}" or "${LEGACY_KEYCHAIN_SERVICE}". ` +
    'See docs/RELEASE.md.',
  );
}

function loadSigningOverride() {
    if (!fs.existsSync(LOCAL_SIGNING_CONFIG)) {
        return undefined;
    }

    const local = JSON.parse(fs.readFileSync(LOCAL_SIGNING_CONFIG, 'utf8')) as LocalSigningConfig;
    const localMaterial = local.material as unknown as Record<string, unknown>;

    if ('storePassword' in localMaterial || 'keyPassword' in localMaterial) {
        throw new Error(
            `${path.relative(process.cwd(), LOCAL_SIGNING_CONFIG)} must not contain passwords.`,
        );
    }

    return {
        type: local.type,
        material: {
            ...local.material,
            storePassword: readKeychainSecret('storePassword'),
            keyPassword: readKeychainSecret('keyPassword'),
        },
    };
}

const signingOverride = loadSigningOverride();

export default {
    ...(signingOverride ? {
        config: {
            ohos: {
                overrides: {
                    signingConfig: signingOverride,
                },
            },
        },
    } : {}),
    system: appTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[flutterHvigorPlugin(path.dirname(__dirname))]         /* Custom plugin to extend the functionality of Hvigor. */
}
