using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc;
using Poc.Api.Infrastructure;

namespace Poc.Api.Models;

/// <summary>Query parameters for the directory-wide user search. Validated before the endpoint runs.</summary>
public sealed class UserSearchRequest : IValidatableObject
{
    /// <summary>Free-text fragment matched against displayName, mail and userPrincipalName.</summary>
    [FromQuery(Name = "search")]
    [StringLength(64, MinimumLength = 2, ErrorMessage = "Search must be between 2 and 64 characters.")]
    // Deliberately restrictive: the value is interpolated into a Graph $search expression.
    [RegularExpression(@"^[A-Za-z0-9 ._@'-]+$", ErrorMessage = "Search may only contain letters, digits, spaces and . _ @ ' -")]
    public string? Search { get; init; }

    /// <summary>Department prefix (case-insensitive), applied as a Graph $filter.</summary>
    [FromQuery(Name = "department")]
    [StringLength(64, MinimumLength = 2, ErrorMessage = "Department must be between 2 and 64 characters.")]
    // Interpolated into an OData string literal; quotes are escaped as well.
    [RegularExpression(@"^[A-Za-z0-9 ._&/'-]+$", ErrorMessage = "Department may only contain letters, digits, spaces and . _ & / ' -")]
    public string? Department { get; init; }

    /// <summary>Maximum number of users to return.</summary>
    [FromQuery(Name = "top")]
    [Range(1, 50, ErrorMessage = "Top must be between 1 and 50.")]
    [DefaultValue(10)]
    public int Top { get; init; } = 10;

    /// <summary>
    /// Comma-separated properties to return. Every name must appear in the catalog exposed by
    /// <c>GET /api/users/properties</c>; omit for the default set.
    /// </summary>
    [FromQuery(Name = "select")]
    [StringLength(512)]
    [SelectableUserProperties]
    public string? Select { get; init; }

    public IEnumerable<ValidationResult> Validate(ValidationContext validationContext)
    {
        if (string.IsNullOrWhiteSpace(Search) && string.IsNullOrWhiteSpace(Department))
        {
            yield return new ValidationResult(
                "Provide a search term, a department, or both.", [nameof(Search), nameof(Department)]);
        }
    }
}

/// <summary>Route parameter for a single-user lookup.</summary>
public sealed class UserLookupRequest
{
    /// <summary>Object id (GUID) or userPrincipalName of the target user.</summary>
    [FromRoute(Name = "id")]
    [Required(AllowEmptyStrings = false)]
    [StringLength(128, MinimumLength = 3)]
    [RegularExpression(
        @"^(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})$",
        ErrorMessage = "Id must be a GUID or a userPrincipalName.")]
    public string Id { get; init; } = string.Empty;
}
