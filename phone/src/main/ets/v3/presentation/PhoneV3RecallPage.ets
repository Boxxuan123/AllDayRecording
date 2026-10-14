import { PhoneRecallSearch } from './PhoneRecallSearch';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
@Component
export struct PhoneV3RecallPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession:(session:PhoneV3SessionCard)=>void=():void=>{};
  onOpenPeople:()=>void=():void=>{};
  build(){PhoneRecallSearch({viewModel:this.viewModel,onOpenSession:this.onOpenSession,onOpenPeople:this.onOpenPeople})}
}
