import { HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { from, switchMap } from 'rxjs';
import { environment } from '../../environments/environment';
import { AuthService } from './auth.service';

/** Attaches the API access token to outbound calls that target the .NET API. */
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  if (!req.url.startsWith(environment.apiBaseUrl)) {
    return next(req);
  }

  const auth = inject(AuthService);

  return from(auth.getApiAccessToken()).pipe(
    switchMap((token) => next(req.clone({ setHeaders: { Authorization: `Bearer ${token}` } }))),
  );
};
