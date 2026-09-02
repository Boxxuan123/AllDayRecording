import { ChipV2Label, ChipV2Options, uiMaterial } from '@kit.ArkUI';

export const PHONE_V3_FLOATING_TAB_BAR_HEIGHT: number = 62;
export const PHONE_V3_FLOATING_TAB_BAR_BOTTOM_MARGIN: number = 14;
export const PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET: number =
  PHONE_V3_FLOATING_TAB_BAR_HEIGHT + PHONE_V3_FLOATING_TAB_BAR_BOTTOM_MARGIN;
export const PHONE_V3_BACKUP_ACTION_HEIGHT: number = 52;
export const PHONE_V3_BACKUP_ACTION_BOTTOM_MARGIN: number =
  PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET + 16;
export const PHONE_V3_BACKUP_ACTION_CONTENT_END_OFFSET: number =
  PHONE_V3_BACKUP_ACTION_BOTTOM_MARGIN + PHONE_V3_BACKUP_ACTION_HEIGHT + 16;

export function phoneV3ImmersiveMaterial(): uiMaterial.Material {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    colorInvert: true,
    interactive: true,
    lightEffect: { color: undefined }
  });
}

export function phoneV3StatusChip(label: string): ChipV2Options {
  return new ChipV2Options({
    label: new ChipV2Label({ text: label }),
    allowClose: false,
    backgroundSystemMaterial: phoneV3ImmersiveMaterial()
  });
}
