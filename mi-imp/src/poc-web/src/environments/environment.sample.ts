/**
 * Template for environment.ts, which is git-ignored because its ids are tenant-specific.
 * Run mi-imp/infra/entra/setup-entra.ps1 -ApplyLocalConfig to generate the real file, or copy
 * this one to environment.ts and fill in the placeholders by hand.
 */
export const environment = {
  tenantId: '<tenant-id>',
  spaClientId: '<spa-client-id>',

  /** Entra ID authority host for this cloud, e.g. https://login.microsoftonline.us/ in Azure Government. */
  authorityHost: 'https://login.microsoftonline.com/',

  redirectUri: 'http://localhost:4200',
  postLogoutRedirectUri: 'http://localhost:4200',

  /** Scope exposed by the .NET API. */
  apiScopes: ['api://<api-client-id>/access_as_user'],

  apiBaseUrl: 'https://localhost:7182/api',
};
