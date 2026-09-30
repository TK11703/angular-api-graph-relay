using System.ComponentModel.DataAnnotations;
using Microsoft.Graph.Models;
using Poc.Api.Models;

namespace Poc.Api.Infrastructure;

/// <summary>
/// Allow-list of the Graph user properties a client may request. Names only ever reach a Graph
/// query after matching an entry here, so caller input cannot shape the $select or $search clause.
/// </summary>
internal static class UserPropertyCatalog
{
    private sealed record Property(string Name, string Label, Func<User, string?> Read);

    private static readonly Property[] All =
    [
        new("displayName", "Display name", u => u.DisplayName),
        new("userPrincipalName", "UPN", u => u.UserPrincipalName),
        new("mail", "Mail", u => u.Mail),
        new("givenName", "First name", u => u.GivenName),
        new("surname", "Last name", u => u.Surname),
        new("jobTitle", "Job title", u => u.JobTitle),
        new("department", "Department", u => u.Department),
        new("companyName", "Company", u => u.CompanyName),
        new("employeeId", "Employee id", u => u.EmployeeId),
        new("officeLocation", "Office", u => u.OfficeLocation),
        new("city", "City", u => u.City),
        new("state", "State", u => u.State),
        new("country", "Country", u => u.Country),
        new("mobilePhone", "Mobile phone", u => u.MobilePhone),
        new("businessPhones", "Business phones", u => u.BusinessPhones is { Count: > 0 } p ? string.Join(", ", p) : null),
        new("preferredLanguage", "Language", u => u.PreferredLanguage),
        new("userType", "User type", u => u.UserType),
        new("accountEnabled", "Account enabled", u => u.AccountEnabled?.ToString()),
    ];

    private static readonly Dictionary<string, Property> ByName =
        All.ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);

    /// <summary>The subset Graph's $search clause actually probes. Surfaced so the UI can say so.</summary>
    private static readonly string[] SearchedNames = ["displayName", "mail", "userPrincipalName"];

    internal static readonly string[] DefaultNames =
        ["displayName", "userPrincipalName", "jobTitle", "department"];

    // Alphabetical for the picker only; result columns still follow the declaration order of All.
    internal static IReadOnlyList<UserPropertyDescriptor> Selectable { get; } =
        Describe(All.OrderBy(p => p.Label, StringComparer.OrdinalIgnoreCase));

    internal static IReadOnlyList<UserPropertyDescriptor> Searched { get; } =
        Describe(SearchedNames.Select(n => ByName[n]));

    internal static bool IsKnown(string name) => ByName.ContainsKey(name);

    internal static string[] Split(string? select) =>
        select?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? [];

    /// <summary>Maps a caller's comma-separated list onto catalog order, falling back to the defaults.</summary>
    internal static IReadOnlyList<UserPropertyDescriptor> Resolve(string? select)
    {
        var requested = Split(select);
        var names = requested.Length == 0 ? DefaultNames : requested;

        return Describe(All.Where(p => names.Contains(p.Name, StringComparer.OrdinalIgnoreCase)));
    }

    internal static string[] GraphSelect(IReadOnlyList<UserPropertyDescriptor> fields) =>
        // id identifies the row and displayName backs the $orderby, whether or not they were asked for.
        new[] { "id", "displayName" }
            .Concat(fields.Select(f => f.Name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();

    internal static string BuildSearchExpression(string term) =>
        string.Join(" OR ", SearchedNames.Select(name => $"\"{name}:{term}\""));

    internal static UserRow Project(User user, IReadOnlyList<UserPropertyDescriptor> fields) =>
        new(user.Id, fields.ToDictionary(f => f.Name, f => ByName[f.Name].Read(user)));

    private static UserPropertyDescriptor[] Describe(IEnumerable<Property> properties) =>
        properties.Select(p => new UserPropertyDescriptor(p.Name, p.Label)).ToArray();
}

/// <summary>Rejects requested properties that are not in <see cref="UserPropertyCatalog"/>.</summary>
[AttributeUsage(AttributeTargets.Property)]
internal sealed class SelectableUserPropertiesAttribute : ValidationAttribute
{
    protected override ValidationResult? IsValid(object? value, ValidationContext validationContext)
    {
        var unknown = UserPropertyCatalog.Split(value as string)
            .Where(name => !UserPropertyCatalog.IsKnown(name))
            .ToArray();

        return unknown.Length == 0
            ? ValidationResult.Success
            : new ValidationResult($"Unknown properties: {string.Join(", ", unknown)}.");
    }
}
