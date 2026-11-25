import { getTransport } from '../../api/transport';
import { useCoordinatorStore, useLibraryStore } from '../../stores';
import type { MaterialPackageImportResult } from '../../types/domain';

export async function runMaterialPackageImport(
  mode: 'files' | 'directory',
  explicitTargetFolderId?: string | null,
): Promise<MaterialPackageImportResult[]> {
  const transport = getTransport();
  const coord = useCoordinatorStore.getState();
  const lib = useLibraryStore.getState();

  const targetFolderId =
    explicitTargetFolderId !== undefined
      ? explicitTargetFolderId
      : coord.destination.type === 'folder'
        ? coord.destination.id
        : null;

  let selectedPaths: string[] = [];
  if (mode === 'files') {
    selectedPaths = await transport.pickMaterialPackageFilesDialog();
  } else {
    const dir = await transport.pickDirectoryDialog('选择外部素材库目录 (.library)');
    if (dir) {
      selectedPaths = [dir];
    }
  }

  if (selectedPaths.length === 0) {
    return [];
  }

  const progressToastId = coord.pushToast({
    message: '正在解析并导入素材包…',
    tone: 'info',
    durationMs: 30_000,
  });

  try {
    const results = await transport.importMaterialPackages(selectedPaths, targetFolderId, null);
    coord.dismissToast(progressToastId);

    if (results.length === 0) {
      coord.pushToast({ message: '未检测到可导入的素材包内容', tone: 'info' });
      return [];
    }

    const nextDest =
      results.length === 1 && results[0].rootFolderID
        ? ({ type: 'folder', id: results[0].rootFolderID } as const)
        : coord.destination;

    if (results.length === 1 && results[0].rootFolderID) {
      coord.setDestination(nextDest);
    }
    await lib.refreshAll(nextDest);

    if (results.length === 1) {
      const r = results[0];
      const skippedSuffix =
        r.skippedDeletedCount > 0 || r.skippedMissingCount > 0
          ? `（已跳过 ${r.skippedDeletedCount + r.skippedMissingCount} 项）`
          : '';
      coord.pushToast({
        message: `已导入「${r.packageName}」：新建 ${r.createdFolderCount} 个文件夹，收入 ${r.importedAssetCount} 项素材${skippedSuffix}`,
        tone: 'success',
      });
    } else {
      const totalAssets = results.reduce((sum, r) => sum + r.importedAssetCount, 0);
      const totalFolders = results.reduce((sum, r) => sum + r.createdFolderCount, 0);
      coord.pushToast({
        message: `已导入 ${results.length} 个素材包：新建 ${totalFolders} 个文件夹，收入 ${totalAssets} 项素材`,
        tone: 'success',
      });
    }

    return results;
  } catch (err) {
    coord.dismissToast(progressToastId);
    coord.pushToast({
      message: `素材包导入失败：${err instanceof Error ? err.message : String(err)}`,
      tone: 'error',
    });
    return [];
  }
}
