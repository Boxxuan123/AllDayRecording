import { HvigorPlugin } from '@ohos/hvigor';
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { execFileSync } from 'child_process';
import path from 'path';

const buildIdentityPlugin: HvigorPlugin = {
  pluginId: 'alldayrecording-build-identity',
  apply(node) {
    const root = node.getNodeDir().getPath();
    execFileSync(process.execPath, [path.resolve(root, 'tools/quality/generate-build-identity.mjs'), root],
      { cwd: root, stdio: 'inherit', timeout: 10000 });
  }
};

const codeLinterPlugin: HvigorPlugin = {
  pluginId: 'alldayrecording-code-linter',
  apply(node) {
    node.registerTask({
      name: 'codeLinter',
      run() {
        const projectRoot = node.getNodeDir().getPath();
        const runner = path.resolve(projectRoot, 'tools/quality/run-code-linter.mjs');
        execFileSync(process.execPath, [runner, projectRoot], {
          cwd: projectRoot,
          stdio: 'inherit'
        });
      }
    });
  }
};

const hostTestPlugin: HvigorPlugin = {
  pluginId: 'alldayrecording-host-tests',
  apply(node) {
    node.registerTask({
      name: 'hostTest',
      run() {
        const projectRoot = node.getNodeDir().getPath();
        const runner = path.resolve(projectRoot, 'tools/quality/run-host-tests.mjs');
        execFileSync(process.execPath, [runner, projectRoot], {
          cwd: projectRoot,
          stdio: 'inherit'
        });
      }
    });
  }
};

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [buildIdentityPlugin, codeLinterPlugin, hostTestPlugin]
}
