close all
%% Monza 2026 Q: braking energy available to an ERS
T = readtable("Monza_2026_Q_clean.csv");
t = T.t_s;  x = T.Distance;  v = T.Speed/3.6;   % s, m, m/s

%% Assumptions (state all of these in the write-up)
m       = 780;     % kg: 768 kg minimum (with driver, no fuel) + estimated quali fuel
rho     = 1.2;     % air density, kg/m^3
CdA     = 1.0;     % drag area, m^2 (estimate, low-drag Monza setup)
Crr     = 0.015;   % rolling resistance coefficient (estimate)
eta     = 0.85;    % MGU-K + inverter recovery efficiency (estimate)
P_MAX   = 350e3;   % MGU-K harvest power limit, W (2026 regulations)
E_LIMIT = 5e6;     % Monza 2026 qualifying recharge limit, J (reported Sep 2026)
g       = 9.81;

%% Forces and power
a       = gradient(v, t);                    % m/s^2
F_drag  = 0.5*rho*CdA*v.^2;
F_roll  = Crr*m*g;
F_brake = max(-m*a - F_drag - F_roll, 0);    % only what the brakes provide
F_brake(a >= 0) = 0;
P_brake = F_brake .* v;                      % W
P_rec   = min(eta*P_brake, P_MAX);           % W, what the ERS could take

%% Find braking zones (brake power above 50 kW)
inZone = P_brake > 50e3;
d = diff([0; inZone; 0]);
s = find(d == 1);  e = find(d == -1) - 1;

% Merge zones separated by 3 samples or fewer (one corner split by noise)
k = 1;
while k < numel(s)
    if s(k+1) - e(k) <= 3
        e(k) = e(k+1);  s(k+1) = [];  e(k+1) = [];
    else
        k = k + 1;
    end
end
% Drop single-sample zones (no energy can be integrated)
keep = (e - s) >= 1;  s = s(keep);  e = e(keep);

%% Corner names by approximate start distance on this lap
cornerNames = ["Rettifilo", "Roggia", "Lesmo 1", "Lesmo 2", "Ascari", "Alboreto"];
cornerDist  = [730, 1970, 2440, 2760, 3800, 4990];

nz = numel(s);
Corner = strings(nz,1);  StartDist_m = zeros(nz,1);  SpeedIn_kmh = zeros(nz,1);
SpeedOut_kmh = zeros(nz,1);  E_brake_kJ = zeros(nz,1);  E_recov_kJ = zeros(nz,1);
for k = 1:nz
    idx = s(k):e(k);
    StartDist_m(k)  = x(idx(1));
    [~, ci] = min(abs(cornerDist - StartDist_m(k)));
    Corner(k)       = cornerNames(ci);
    SpeedIn_kmh(k)  = T.Speed(idx(1));
    SpeedOut_kmh(k) = T.Speed(idx(end));
    E_brake_kJ(k)   = trapz(t(idx), P_brake(idx))/1e3;
    E_recov_kJ(k)   = trapz(t(idx), P_rec(idx))/1e3;
end
Recovered_pct = round(100 * E_recov_kJ ./ E_brake_kJ);
Zones = table(Corner, StartDist_m, SpeedIn_kmh, SpeedOut_kmh, E_brake_kJ, E_recov_kJ, Recovered_pct)

%% Totals and the shortfall against the 5 MJ limit
E_tot = sum(E_brake_kJ)/1e3;           % MJ
E_rec = sum(E_recov_kJ)/1e3;           % MJ
E_short = E_LIMIT/1e6 - E_rec;         % MJ still needed from elsewhere
t_clip  = E_short*1e6 / P_MAX;         % s of 350 kW superclipping to cover it

fprintf("Total braking energy:       %.2f MJ\n", E_tot);
fprintf("Recoverable from braking:   %.2f MJ (%.0f%%)\n", E_rec, 100*E_rec/E_tot);
fprintf("Shortfall vs 5 MJ limit:    %.2f MJ (about %.1f s of 350 kW superclipping)\n", E_short, t_clip);

%% Figure 1: speed and braking power
figure
subplot(2,1,1)
plot(x, T.Speed); grid on; ylabel("Speed (km/h)")
title("Monza 2026 Q, driver 63: braking power available to the ERS")
for k = 1:nz
    text(StartDist_m(k), SpeedIn_kmh(k) + 12, Corner(k), "FontSize", 8, "HorizontalAlignment", "center")
end
ylim([50 380])
subplot(2,1,2)
plot(x, P_brake/1e3); hold on
plot(x, P_rec/1e3, "LineWidth", 1.2)
yline(P_MAX/1e3, "--", "MGU-K limit"); grid on
ylabel("Power (kW)"); xlabel("Distance (m)")
legend("Brake power", "Recoverable power", "Location", "northwest")

%% Figure 2: energy per corner
figure
bar(categorical(Corner, Corner), [E_brake_kJ E_recov_kJ]/1e3); grid on
ylabel("Energy (MJ)")
legend("Available from braking", "Recoverable by ERS (350 kW cap)")
title({sprintf("Monza 2026 Q: %.2f MJ available from braking, %.2f MJ recoverable (%.0f%%)", ...
    E_tot, E_rec, 100*E_rec/E_tot), ...
    sprintf("5 MJ qualifying limit leaves %.2f MJ to harvest elsewhere (about %.1f s of superclipping)", ...
    E_short, t_clip)})
for k = 1:nz
    text(k + 0.14, E_recov_kJ(k)/1e3 + 0.05, sprintf("%d%%", Recovered_pct(k)), ...
        "HorizontalAlignment", "center", "FontSize", 8)
end

%% Test: sustained deceleration at full throttle, no brake (superclipping signature)
v_s  = smoothdata(v, "movmean", 5);           % speed is in whole km/h, so smooth first
a_s  = gradient(v_s, t);

% Exclude the 0.7 s before each brake application (smoothing smear and throttle lag)
brakeOn = find(diff([0; T.Brake > 0]) == 1);
nearBrake = false(size(t));
for b = brakeOn'
    nearBrake = nearBrake | (t >= t(b) - 0.7 & t <= t(b));
end

cand = T.Throttle >= 98 & T.Brake == 0 & a_s < -1.0 & ~nearBrake;
sustained = movsum(cand, [2 0]) >= 3;          % 3+ consecutive samples
sustained = sustained | [sustained(2:end); false] | [sustained(3:end); false; false];
clip = cand & sustained;

dt = [diff(t); 0];
fprintf("Sustained full-throttle deceleration: %.1f s per lap (needed: at least %.1f s at 350 kW)\n", ...
    sum(dt(clip)), t_clip);

figure
plot(x, T.Speed); hold on
plot(x(clip), T.Speed(clip), "m.", "MarkerSize", 12); grid on
xlabel("Distance (m)"); ylabel("Speed (km/h)")
title("Magenta: sustained slowing at full throttle, away from braking")
legend("Speed", "Sustained full-throttle deceleration", "Location", "southwest")

%% Save the two README figures as image files
if ~exist("figures", "dir"), mkdir("figures"); end
exportgraphics(figure(1), "figures/speed_and_braking_power.png", "Resolution", 300)
exportgraphics(figure(2), "figures/energy_per_corner.png", "Resolution", 300)