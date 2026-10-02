import { Injectable, computed, signal } from '@angular/core';
import {
  AccountInfo,
  Configuration,
  IPublicClientApplication,
  InteractionRequiredAuthError,
  LogLevel,
  createStandardPublicClientApplication,
} from '@azure/msal-browser';

import { environment } from '../../environments/environment';

const msalConfig: Configuration = {
  auth: {
    clientId: environment.spaClientId,
    authority: new URL(environment.tenantId, environment.authorityHost).toString(),
    redirectUri: environment.redirectUri,
    postLogoutRedirectUri: environment.postLogoutRedirectUri,
  },
  cache: {
    cacheLocation: 'sessionStorage',
  },
  system: {
    loggerOptions: {
      logLevel: LogLevel.Warning,
      loggerCallback: (_level, message, containsPii) => {
        if (!containsPii) {
          console.debug(message);
        }
      },
    },
  },
};

@Injectable({ providedIn: 'root' })
export class AuthService {
  private msal!: IPublicClientApplication;
  private readonly account = signal<AccountInfo | null>(null);

  readonly isSignedIn = computed(() => this.account() !== null);
  readonly displayName = computed(() => this.account()?.name ?? this.account()?.username ?? '');
  readonly username = computed(() => this.account()?.username ?? '');

  /** Awaited during bootstrap so the redirect response is processed before the UI renders. */
  async initialize(): Promise<void> {
    this.msal = await createStandardPublicClientApplication(msalConfig);

    const redirectResult = await this.msal.handleRedirectPromise();
    const active =
      redirectResult?.account ?? this.msal.getActiveAccount() ?? this.msal.getAllAccounts()[0] ?? null;

    if (active) {
      this.msal.setActiveAccount(active);
    }
    this.account.set(active);
  }

  signIn(): Promise<void> {
    return this.msal.loginRedirect({ scopes: environment.apiScopes });
  }

  signOut(): Promise<void> {
    return this.msal.logoutRedirect({ account: this.msal.getActiveAccount() ?? undefined });
  }

  /** Token for the .NET API only - Graph is never called from the browser. */
  async getApiAccessToken(): Promise<string> {
    const account = this.msal.getActiveAccount();
    if (!account) {
      throw new Error('No signed-in account.');
    }

    try {
      const result = await this.msal.acquireTokenSilent({ account, scopes: environment.apiScopes });
      return result.accessToken;
    } catch (error) {
      if (error instanceof InteractionRequiredAuthError) {
        await this.msal.acquireTokenRedirect({ account, scopes: environment.apiScopes });
      }
      throw error;
    }
  }
}
