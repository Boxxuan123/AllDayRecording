import { DeviceV3PersonChoice } from '../../computer/ComputerTransferProtocol';

// A page owns its generation; callbacks from an older opening/save cannot replace its choices.
export class PhoneV3PeopleLoader {
  private generation: number = 0;
  refresh(load: (accept: (people: Array<DeviceV3PersonChoice>) => void) => void,
    accept: (people: Array<DeviceV3PersonChoice>) => void): void {
    const generation = ++this.generation;
    load((people: Array<DeviceV3PersonChoice>): void => {
      if (generation === this.generation) { accept(people); }
    });
  }
}
