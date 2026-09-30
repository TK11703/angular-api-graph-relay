using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Identity.Web;
using Poc.Api.Authorization;
using Poc.Api.Endpoints;
using Poc.Api.Infrastructure;

var builder = WebApplication.CreateBuilder(args);

// Validates the incoming access token issued by Entra ID, and enables the
// on-behalf-of flow so this API can call Microsoft Graph as the signed-in user.
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
        .EnableTokenAcquisitionToCallDownstreamApi()
        .AddMicrosoftGraph(builder.Configuration.GetSection("MicrosoftGraph"))
        .AddInMemoryTokenCaches();

builder.Services.Configure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
{
    // Without this the inbound "roles"/"name" claims are renamed to the legacy WS-* claim
    // URIs, and the claim types configured below would never match.
    options.MapInboundClaims = false;
    options.TokenValidationParameters.NameClaimType = "name";
    options.TokenValidationParameters.RoleClaimType = "roles";
});

builder.Services.AddRequiredScopeAuthorization();
builder.Services.AddAuthorizationBuilder()
    .SetDefaultPolicy(new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .RequireScope(Policies.ApiScope)
        .Build())
    .AddPolicy(Policies.ApplicationAdmin, policy => policy
        .RequireAuthenticatedUser()
        .RequireScope(Policies.ApiScope)
        .RequireRole(Policies.ApplicationAdminRole));

// Minimal API parameter/DTO validation (DataAnnotations -> 400 ValidationProblemDetails).
builder.Services.AddValidation();

builder.Services.AddProblemDetails();
builder.Services.AddExceptionHandler<GraphExceptionHandler>();
builder.Services.AddOpenApi();

var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
builder.Services.AddCors(options => options.AddDefaultPolicy(policy => policy
    .WithOrigins(allowedOrigins)
    .AllowAnyHeader()
    .AllowAnyMethod()));

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();
app.UseCors();
app.UseAuthentication();
app.UseAuthorization();

var api = app.MapGroup("/api").RequireAuthorization();
api.MapMeEndpoints();
api.MapUserEndpoints();

app.Run();
