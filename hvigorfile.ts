import { HvigorPlugin } from '@ohos/hvigor';
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { execFileSync } from 'child_process';
import path from 'path';

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

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [codeLinterPlugin]
}
