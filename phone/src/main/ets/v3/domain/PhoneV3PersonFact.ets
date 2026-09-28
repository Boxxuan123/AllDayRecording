interface PersonAnnotation { person_id?: string; source?: string; state?: string; }
interface PersonReviewDimensions { person?: Array<string>; sound?: Array<string>; }
interface PersonReview { dimensions?: PersonReviewDimensions; }
interface AnnotationFactIds { person?: Array<string>; sound?: Array<string>; }
export interface PhoneV3Evidence {
  person_annotation?: PersonAnnotation;
  annotation_outdated?: Array<string>;
  annotation_review?: PersonReview;
  annotation_fact_ids?: AnnotationFactIds;
  sound_kind?: string;
}

// Server evidence is authoritative only while its person dimension is current.
// Sound exclusions are independent of identity.
export function phoneV3PersonFact(evidenceJson: string, parsed?: PhoneV3Evidence): string {
  try {
    const evidence = parsed ?? JSON.parse(evidenceJson) as PhoneV3Evidence;
    const fact = evidence.person_annotation;
    if (fact === undefined || evidence.annotation_outdated?.includes('person') ||
      evidence.annotation_review?.dimensions?.person !== undefined ||
      (fact.state !== undefined && fact.state !== 'active')) { return ''; }
    return typeof fact.person_id === 'string' ? fact.person_id : '';
  } catch (error) { return ''; }
}

export function phoneV3PersonUncertain(evidenceJson: string, parsed?: PhoneV3Evidence): boolean {
  try {
    const evidence = parsed ?? JSON.parse(evidenceJson) as PhoneV3Evidence;
    return (evidence.person_annotation !== undefined && phoneV3PersonFact(evidenceJson, evidence).length === 0) ||
      evidence.annotation_review?.dimensions?.person !== undefined ||
      evidence.annotation_outdated?.includes('person') === true;
  } catch (error) { return true; }
}
