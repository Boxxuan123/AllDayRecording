import { ChipV2Label, ChipV2Options, uiMaterial } from '@kit.ArkUI';

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
