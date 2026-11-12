import { hapTasks } from '@ohos/hvigor-ohos-plugin';
import { hvigor } from '@ohos/hvigor';
import { ensureMtaNative } from '../scripts/mta-native-build';

// 同步只加载工程模型；原生工具链检查必须等实际构建任务执行。
hvigor.taskGraphResolved(() => {
  const commands = hvigor.getCommandEntryTask() || [];
  // init 用于 IDE 工程同步，clean/tasks/taskTree 同样不需要原生工具链。
  if (commands.some(name => !/^(?:.*[:@])?(?:init|clean|tasks|taskTree)$/.test(name))) {
    console.info('[MTA] 检查原生传输库（构建前置）');
    ensureMtaNative(__dirname);
  }
});

export default {
  system: hapTasks,
  plugins: []
};
