import { HttpClient, HttpParams } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable } from 'rxjs';
import { environment } from '../../environments/environment';
import {
  DirectoryGroup,
  SignedInUser,
  UserProfile,
  UserPropertyCatalog,
  UserSearchResponse,
  UserUpdate,
} from './models';

@Injectable({ providedIn: 'root' })
export class ApiService {
  private readonly http = inject(HttpClient);
  private readonly baseUrl = environment.apiBaseUrl;

  getMyContext(): Observable<SignedInUser> {
    return this.http.get<SignedInUser>(`${this.baseUrl}/me/context`);
  }

  getMyProfile(): Observable<UserProfile> {
    return this.http.get<UserProfile>(`${this.baseUrl}/me`);
  }

  getMyGroups(): Observable<DirectoryGroup[]> {
    return this.http.get<DirectoryGroup[]>(`${this.baseUrl}/me/groups`);
  }

  /** Which properties may be requested, and which ones the directory search actually probes. */
  getUserProperties(): Observable<UserPropertyCatalog> {
    return this.http.get<UserPropertyCatalog>(`${this.baseUrl}/users/properties`);
  }

  searchUsers(search: string, department: string, select: string[], top = 10): Observable<UserSearchResponse> {
    let params = new HttpParams().set('top', top);
    if (search) {
      params = params.set('search', search);
    }
    if (department) {
      params = params.set('department', department);
    }
    if (select.length) {
      params = params.set('select', select.join(','));
    }

    return this.http.get<UserSearchResponse>(`${this.baseUrl}/users`, { params });
  }

  getUser(id: string): Observable<UserProfile> {
    return this.http.get<UserProfile>(`${this.baseUrl}/users/${encodeURIComponent(id)}`);
  }

  getUserGroups(id: string): Observable<DirectoryGroup[]> {
    return this.http.get<DirectoryGroup[]>(`${this.baseUrl}/users/${encodeURIComponent(id)}/groups`);
  }

  /** Requires the ApplicationAdmin app role; returns the profile as re-read from Graph. */
  updateUser(id: string, update: UserUpdate): Observable<UserProfile> {
    return this.http.patch<UserProfile>(`${this.baseUrl}/users/${encodeURIComponent(id)}`, update);
  }
}
