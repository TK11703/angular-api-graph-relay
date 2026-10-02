using Azure.Core;
using Azure.Identity;
using Microsoft.Graph;

namespace Poc.Api.Infrastructure;

/// <summary>Whose identity the API presents to Microsoft Graph.</summary>
public enum GraphAuthMode
{
    /// <summary>Delegated: the signed-in user's token is exchanged on-behalf-of the user.</summary>
    OnBehalfOf,

    /// <summary>App-only: the API's managed identity calls Graph with its own application permissions.</summary>
    ManagedIdentity
}

public static class GraphAccess
{
    public const string SectionName = "GraphAccess";

    public static GraphAuthMode GetGraphAuthMode(this IConfiguration configuration) =>
        configuration.GetValue($"{SectionName}:Mode", GraphAuthMode.OnBehalfOf);

    /// <summary>
    /// Registers a <see cref="GraphServiceClient"/> that authenticates as the managed identity.
    /// <c>GraphAccess:ManagedIdentityClientId</c> selects a user-assigned identity; omit it for system-assigned.
    /// </summary>
    public static IServiceCollection AddManagedIdentityGraphClient(this IServiceCollection services, IConfiguration configuration)
    {
        var baseUrl = configuration["MicrosoftGraph:BaseUrl"] ?? "https://graph.microsoft.com/v1.0";
        // App-only tokens use the resource's .default scope, which follows the cloud (graph.microsoft.us in Gov).
        var scope = $"{new Uri(baseUrl).GetLeftPart(UriPartial.Authority)}/.default";

        var clientId = configuration[$"{SectionName}:ManagedIdentityClientId"];
        TokenCredential credential = new ManagedIdentityCredential(string.IsNullOrWhiteSpace(clientId)
            ? ManagedIdentityId.SystemAssigned
            : ManagedIdentityId.FromUserAssignedClientId(clientId));

        services.AddSingleton(new GraphServiceClient(credential, [scope], baseUrl));
        return services;
    }
}
