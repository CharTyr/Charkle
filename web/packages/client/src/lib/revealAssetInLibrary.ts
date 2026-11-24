import { buildFolderPathsMap, clearVisualFilters } from '@charkle/shared';
import type { AssetRecord, FolderRecord, SidebarDestination, UUID } from '@charkle/shared';
import { apiClient } from '../api/client';
import { useCoordinatorStore } from '../stores/coordinatorStore';
import { useLibraryStore } from '../stores/libraryStore';
import { useMoodboardStore } from '../stores/moodboardStore';

export interface RevealReturnBoardContext {
  returnBoardId?: UUID | null;
  returnBoardTitle?: string | null;
}

function collectAncestorFolderIDs(
  folderID: UUID,
  folders: readonly FolderRecord[],
): UUID[] {
  const byID = new Map<UUID, FolderRecord>(folders.map((f) => [f.id, f]));
  const ancestors: UUID[] = [];
  const seen = new Set<UUID>();
  let current = byID.get(folderID);
  while (current && !seen.has(current.id)) {
    seen.add(current.id);
    if (current.parentID && byID.has(current.parentID)) {
      ancestors.push(current.parentID);
      current = byID.get(current.parentID);
    } else {
      break;
    }
  }
  return ancestors;
}

/**
 * Reveals an asset in the main Library Gallery with full parity to macOS `revealAssetInLibrary`:
 * 1. Resolves asset from memory or server (warns cleanly if deleted).
 * 2. Closes Quick Look, expands ancestor folders in sidebar, navigates to owning destination.
 * 3. Clears conflicting search/visual/semantic filters if the asset is hidden by them.
 * 4. Selects the asset, triggers gallery centering + cobalt spotlight pulse (`requestRevealAssetInGallery`).
 * 5. Displays location Toast with optional 1-click "返回情绪板" CTA when invoked from a Moodboard.
 */
export async function revealAssetInLibrary(
  assetID: UUID,
  sourceBoard?: UUID | RevealReturnBoardContext | null,
): Promise<void> {
  const coord = useCoordinatorStore.getState();
  const lib = useLibraryStore.getState();

  const sourceBoardID: UUID | null =
    typeof sourceBoard === 'string'
      ? sourceBoard
      : (sourceBoard?.returnBoardId ?? null);
  const explicitBoardTitle =
    typeof sourceBoard === 'object' && sourceBoard !== null
      ? (sourceBoard.returnBoardTitle ?? null)
      : null;

  let asset: AssetRecord | undefined = lib.assetsByID[assetID];
  if (!asset) {
    try {
      const res = await apiClient.getAsset(assetID);
      if (res.asset) {
        asset = res.asset;
        lib.upsertAssets([res.asset]);
      }
    } catch {
      // Asset no longer exists
    }
  }

  if (!asset) {
    coord.pushToast({
      tone: 'warning',
      message: '该素材已不在素材库中',
    });
    return;
  }

  coord.closeQuickLook();

  const folders = useLibraryStore.getState().folders;
  const folderByID = new Map(folders.map((f) => [f.id, f]));
  const folderPaths = buildFolderPathsMap(folders);

  let targetDestination: SidebarDestination;
  let locationLabel: string;

  if (asset.isTrashed) {
    targetDestination = { type: 'trash' };
    locationLabel = '回收站';
  } else if (asset.folderID && folderByID.has(asset.folderID)) {
    targetDestination = { type: 'folder', id: asset.folderID };
    locationLabel = folderPaths[asset.folderID] || folderByID.get(asset.folderID)!.name;
    const ancestorIDs = collectAncestorFolderIDs(asset.folderID, folders);
    if (ancestorIDs.length > 0) {
      coord.revealSidebarFolderAncestors(ancestorIDs);
    }
  } else if (!asset.folderID) {
    targetDestination = { type: 'inbox' };
    locationLabel = '收件箱';
  } else {
    targetDestination = { type: 'allItems' };
    locationLabel = '全部素材';
  }

  // Flag reveal before navigating so App's destination effect preserves reveal selection
  coord.requestRevealAssetInGallery(assetID);
  coord.navigate(targetDestination);

  await useLibraryStore.getState().loadAssets(targetDestination);

  let foundInView = useLibraryStore.getState().assets.some((item) => item.id === assetID);
  if (!foundInView) {
    // Clear conflicting search, visual filters, and semantic search report
    const currentCriteria = useLibraryStore.getState().criteria;
    useLibraryStore.setState({
      criteria: {
        ...clearVisualFilters(currentCriteria),
        searchQuery: '',
      },
      semanticReport: null,
    });
    await useLibraryStore.getState().loadAssets(targetDestination);
    foundInView = useLibraryStore.getState().assets.some((item) => item.id === assetID);
  }

  if (!foundInView && targetDestination.type !== 'allItems') {
    targetDestination = { type: 'allItems' };
    locationLabel = '全部素材';
    coord.navigate(targetDestination);
    await useLibraryStore.getState().loadAssets(targetDestination);
  }

  useLibraryStore.getState().selectAsset(assetID, 'replace');
  // Re-issue reveal nonce after final list settles so gallery scroll/spotlight executes against mounted items
  useCoordinatorStore.getState().requestRevealAssetInGallery(assetID);

  if (sourceBoardID) {
    const resolvedBoardTitle =
      explicitBoardTitle ||
      useMoodboardStore.getState().boards.find((b) => b.id === sourceBoardID)?.title ||
      null;
    useCoordinatorStore.getState().setReturnToMoodboardState({
      boardID: sourceBoardID,
      boardTitle: resolvedBoardTitle,
    });
    useCoordinatorStore.getState().pushToast({
      tone: 'info',
      message: `已定位到「${locationLabel}」`,
      actionLabel: '返回情绪板',
      durationMs: 6500,
      onAction: () => {
        useCoordinatorStore.getState().openBoard(sourceBoardID);
      },
    });
  } else {
    useCoordinatorStore.getState().pushToast({
      tone: 'info',
      message: `已定位到「${locationLabel}」`,
    });
  }
}
