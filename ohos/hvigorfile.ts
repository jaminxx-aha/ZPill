import { execFileSync } from 'child_process';
import fs from 'fs';
import path from 'path'
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';

const KEYCHAIN_SERVICE = 'com.jaminxx.nikon_pill.ohos-signing';
const LOCAL_SIGNING_CONFIG = path.join(__dirname, 'signing', 'local-signing.json');

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

function readKeychainSecret(account: string): string {
    try {
        const secret = execFileSync(
            '/usr/bin/security',
            ['find-generic-password', '-w', '-s', KEYCHAIN_SERVICE, '-a', account],
            { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
        ).trim();

        if (!secret) {
            throw new Error('empty Keychain value');
        }
        return secret;
    } catch {
        throw new Error(
            `Missing macOS Keychain item "${account}" for service "${KEYCHAIN_SERVICE}". ` +
            'See docs/RELEASE.md.',
        );
    }
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
