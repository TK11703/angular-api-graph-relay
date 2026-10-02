namespace Poc.Api.Models;

public sealed record UserProfile(
    string? Id,
    string? DisplayName,
    string? GivenName,
    string? Surname,
    string? UserPrincipalName,
    string? Mail,
    string? JobTitle,
    string? Department,
    string? OfficeLocation,
    string? MobilePhone,
    string? PreferredLanguage);

/// <summary>A user property the caller may ask for, with a label suitable for a column heading.</summary>
public sealed record UserPropertyDescriptor(string Name, string Label);

/// <summary>One matched user, carrying only the properties that were requested.</summary>
public sealed record UserRow(string? Id, IReadOnlyDictionary<string, string?> Values);

/// <summary>Search results plus the resolved field list, so the client can render columns dynamically.</summary>
public sealed record UserSearchResponse(
    IReadOnlyList<UserPropertyDescriptor> Fields,
    IReadOnlyList<UserRow> Users);

/// <summary>What the client may select, what the search actually probes, and the default selection.</summary>
public sealed record UserPropertyCatalogResponse(
    IReadOnlyList<UserPropertyDescriptor> Selectable,
    IReadOnlyList<UserPropertyDescriptor> Searched,
    IReadOnlyList<string> Defaults);

public sealed record DirectoryGroup(
    string? Id,
    string? DisplayName,
    string? Description);

public sealed record SignedInUser(
    string? ObjectId,
    string? TenantId,
    string? DisplayName,
    string? UserPrincipalName,
    bool IsApplicationAdmin,
    IReadOnlyList<string> Roles,
    IReadOnlyList<string> Scopes);
