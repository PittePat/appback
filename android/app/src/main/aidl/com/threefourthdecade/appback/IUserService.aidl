package com.threefourthdecade.appback;

interface IUserService {
    void destroy() = 16777114; // Required by Shizuku
    String runShellCommand(String command) = 1; 
}
