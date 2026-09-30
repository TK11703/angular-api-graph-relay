export interface SignedInUser {
  objectId: string | null;
  tenantId: string | null;
  displayName: string | null;
  userPrincipalName: string | null;
  isApplicationAdmin: boolean;
  roles: string[];
  scopes: string[];
}

export interface UserProfile {
  id: string | null;
  displayName: string | null;
  givenName: string | null;
  surname: string | null;
  userPrincipalName: string | null;
  mail: string | null;
  jobTitle: string | null;
  department: string | null;
  officeLocation: string | null;
  mobilePhone: string | null;
  preferredLanguage: string | null;
}

export interface UserPropertyDescriptor {
  name: string;
  label: string;
}

export interface UserRow {
  id: string | null;
  values: Record<string, string | null>;
}

export interface UserSearchResponse {
  fields: UserPropertyDescriptor[];
  users: UserRow[];
}

export interface UserPropertyCatalog {
  selectable: UserPropertyDescriptor[];
  searched: UserPropertyDescriptor[];
  defaults: string[];
}

export interface DirectoryGroup {
  id: string | null;
  displayName: string | null;
  description: string | null;
}
