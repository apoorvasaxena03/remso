function [ dh ] = pump_dh(qp)
% Calculates the head difference for the pump at a given flow.
% It can be used to compute upper and lower bounds for the pressure loss
% in the equipment. The coefficients of the curve were found in the paper
% 'Exploring the potential of model-based optimization in oil production
% gathering networks with esp-produced, high water cut wells'.
%    

    a0 = 19.37;       % m 
    a1 = -1.23e-02;     % in m/sm3/d
    a2 = 2.24e-05;      % in m/(sm3/d)^2      
    a3 = -1.86e-08;     % in m/(sm3/d)^3
    a4 = 4.13e-12;      % in m/(sm3/d)^4
    
    qpMetric = qp./(meter^3/day); % in sm3/d
    
    dh = a4.*qpMetric.^4 + a3.*qpMetric.^3 + a2.*qpMetric.^2 + a1.*qpMetric + a0;   % in m
end



